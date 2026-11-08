/*
 * NAPI bridge between ArkTS and the Rust spectral cinema engine.
 *
 * The Rust side (rust/crates/spektrafilm-ffi) exposes a narrow C ABI: file path
 * in, file path out. This shim does the NAPI plumbing and, importantly, moves
 * the render off the JS thread: a 12 MP film simulation takes seconds, and
 * blocking the UI thread on HarmonyOS gets the ability killed.
 *
 * All entry points return a Promise, except the two cheap synchronous getters
 * (version, catalogue).
 */

#include <cstdint>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

#include "napi/native_api.h"
#include "hilog/log.h"

// ---------------------------------------------------------------------------
// Rust C ABI (see rust/crates/spektrafilm-ffi/src/lib.rs)
// ---------------------------------------------------------------------------

extern "C" {
const char *sf_version(void);

int32_t sf_catalog(const char *data_dir,
                   char *out_json,
                   size_t cap,
                   char *err_buf,
                   size_t err_cap);

int32_t sf_render_file(const char *input,
                       const char *output,
                       const char *film,
                       const char *paper,
                       const char *data_dir,
                       const char *params_json,
                       const double *crop,
                       const char *border_json,
                       const char *output_json,
                       uint32_t *out_width,
                       uint32_t *out_height,
                       uint64_t *out_ms,
                       char *err_buf,
                       size_t err_cap);

void sf_string_free(char *s);

int32_t sf_solve_filters(const char *input,
                               const char *data_dir,
                               const char *film,
                               const char *paper,
                               const char *params_json,
                               const double *crop,
                               uint32_t iterations,
                               char **out_json,
                               char *err_buf,
                               size_t err_cap);

int32_t sf_render_test_pattern(uint32_t width,
                               uint32_t height,
                               const char *output,
                               const char *film,
                               const char *paper,
                               const char *data_dir,
                               uint32_t *out_width,
                               uint32_t *out_height,
                               uint64_t *out_ms,
                               char *err_buf,
                               size_t err_cap);

/// Returns the number of bytes written, or a negative error code.
int32_t sf_export_lut(const char *film,
                      const char *paper,
                      const char *data_dir,
                      const char *params_json,
                      uint32_t size,
                      const char *output,
                      char *err_buf,
                      size_t err_cap);

/// Both write JSON into `out_json`; pass NULL/0 to query the needed size.
int32_t sf_preset_import(const char *text,
                         const char *data_dir,
                         const char *current_json,
                         char *out_json,
                         size_t cap,
                         char *err_buf,
                         size_t err_cap);

int32_t sf_merge_params(const char *base_json,
                        const char *over_json,
                        char *out_json,
                        size_t cap,
                        char *err_buf,
                        size_t err_cap);

/// Returns the number of bytes written, or a negative error code.
int32_t sf_preset_export(const char *film,
                         const char *paper,
                         const char *params_json,
                         const char *data_dir,
                         const char *output,
                         char *err_buf,
                         size_t err_cap);
}

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3200
#define LOG_TAG "SpektrafilmNative"

namespace {

constexpr size_t kErrCap = 2048;

// --- small NAPI helpers ----------------------------------------------------

bool GetStringProp(napi_env env, napi_value obj, const char *name, std::string &out) {
    napi_value value = nullptr;
    if (napi_get_named_property(env, obj, name, &value) != napi_ok || value == nullptr) {
        return false;
    }
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_string) {
        return false;
    }
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok) {
        return false;
    }
    out.resize(len);
    size_t written = 0;
    // napi_get_value_string_utf8 writes len bytes plus a NUL; resize to len+1
    // so the terminator has room, then drop it.
    out.resize(len + 1);
    if (napi_get_value_string_utf8(env, value, out.data(), len + 1, &written) != napi_ok) {
        return false;
    }
    out.resize(written);
    return true;
}

bool GetOptionalStringProp(napi_env env, napi_value obj, const char *name, std::string &out) {
    std::string tmp;
    if (!GetStringProp(env, obj, name, tmp)) {
        return false;
    }
    out = tmp;
    return true;
}

bool GetUint32Prop(napi_env env, napi_value obj, const char *name, uint32_t &out) {
    napi_value value = nullptr;
    if (napi_get_named_property(env, obj, name, &value) != napi_ok || value == nullptr) {
        return false;
    }
    uint32_t v = 0;
    if (napi_get_value_uint32(env, value, &v) != napi_ok) {
        return false;
    }
    out = v;
    return true;
}

bool GetDoubleProp(napi_env env, napi_value obj, const char *name, double &out) {
    napi_value value = nullptr;
    if (napi_get_named_property(env, obj, name, &value) != napi_ok || value == nullptr) {
        return false;
    }
    double v = 0;
    if (napi_get_value_double(env, value, &v) != napi_ok) {
        return false;
    }
    out = v;
    return true;
}

napi_value MakeString(napi_env env, const std::string &s) {
    napi_value v = nullptr;
    napi_create_string_utf8(env, s.c_str(), s.size(), &v);
    return v;
}

/// Reads a plain JS string argument.
bool GetStringValue(napi_env env, napi_value value, std::string &out) {
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_string) {
        return false;
    }
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok) {
        return false;
    }
    out.resize(len + 1);
    size_t written = 0;
    if (napi_get_value_string_utf8(env, value, out.data(), len + 1, &written) != napi_ok) {
        return false;
    }
    out.resize(written);
    return true;
}

/// Runs a native call that fills a JSON buffer, handling the two-pass size
/// query the C ABI uses. `fill(buffer, capacity, err)` returns bytes written or
/// a negative error code.
template <typename Fill>
napi_value JsonCall(napi_env env, Fill fill) {
    char err[kErrCap];
    err[0] = '\0';

    int32_t need = fill(nullptr, 0, err);
    if (need < 0) {
        napi_throw_error(env, nullptr, err);
        return nullptr;
    }
    std::vector<char> buf(static_cast<size_t>(need), '\0');
    int32_t written = fill(buf.data(), buf.size(), err);
    if (written < 0) {
        napi_throw_error(env, nullptr, err);
        return nullptr;
    }
    return MakeString(env, std::string(buf.data(), static_cast<size_t>(written)));
}

// --- async render task -----------------------------------------------------

struct RenderTask {
    bool testPattern = false;
    /** Solve the enlarger filter pack instead of rendering a file. */
    bool solve = false;
    int32_t iterations = 4;
    std::string solved;
    std::string input;
    std::string output;
    std::string film;
    std::string paper;    // empty => film's own target_print
    std::string dataDir;
    std::string params;   // empty => defaults
    // [x, y, w, h, angle] in fractions of the frame plus degrees.
    double crop[5] = {0.0, 0.0, 1.0, 1.0, 0.0};
    bool hasCrop = false;
    /** Border request JSON, e.g. {"style":"35mm"}; empty means no border. */
    std::string border;
    /** Export options JSON, e.g. {"quality":92,"bit_depth":16}. */
    std::string output_spec;
    // Requested test-pattern size (input).
    uint32_t width = 0;
    uint32_t height = 0;

    // Result fields.
    int32_t code = 0;
    uint64_t ms = 0;
    uint32_t width_out = 0;
    uint32_t height_out = 0;
    std::string err;

    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
};

const char *Nullable(const std::string &s) {
    return s.empty() ? nullptr : s.c_str();
}

void ExecuteRender(napi_env /*env*/, void *data) {
    auto *t = static_cast<RenderTask *>(data);
    char err[kErrCap];
    err[0] = '\0';

    if (t->solve) {
        char *json = nullptr;
        t->code = sf_solve_filters(t->input.c_str(), t->dataDir.c_str(), t->film.c_str(),
                                   Nullable(t->paper), Nullable(t->params),
                                   t->hasCrop ? t->crop : nullptr,
                                   static_cast<uint32_t>(t->iterations), &json, err, kErrCap);
        if (t->code == 0 && json != nullptr) {
            t->solved = json;
            sf_string_free(json);
        }
    } else if (t->testPattern) {
        t->code = sf_render_test_pattern(t->width, t->height, t->output.c_str(),
                                        t->film.c_str(), Nullable(t->paper),
                                        t->dataDir.c_str(), &t->width_out, &t->height_out,
                                        &t->ms, err, kErrCap);
    } else {
        t->code = sf_render_file(t->input.c_str(), t->output.c_str(), t->film.c_str(),
                                 Nullable(t->paper), t->dataDir.c_str(),
                                 Nullable(t->params), t->hasCrop ? t->crop : nullptr,
                                 Nullable(t->border),
                                 Nullable(t->output_spec),
                                 &t->width_out, &t->height_out, &t->ms, err, kErrCap);
    }
    if (t->code != 0) {
        t->err = err;
        OH_LOG_ERROR(LOG_APP, "render failed (%{public}d): %{public}s", t->code, err);
    } else {
        OH_LOG_INFO(LOG_APP, "render ok in %{public}llu ms",
                    static_cast<unsigned long long>(t->ms));
    }
}

void CompleteRender(napi_env env, napi_status /*status*/, void *data) {
    auto *t = static_cast<RenderTask *>(data);

    if (t->code == 0) {
        if (t->solve) {
            napi_value solved = MakeString(env, t->solved);
            napi_resolve_deferred(env, t->deferred, solved);
            napi_delete_async_work(env, t->work);
            delete t;
            return;
        }
        napi_value result = nullptr;
        napi_create_object(env, &result);
        napi_set_named_property(env, result, "output", MakeString(env, t->output));
        napi_value ms = nullptr;
        napi_create_double(env, static_cast<double>(t->ms), &ms);
        napi_set_named_property(env, result, "elapsedMs", ms);
        // Output dimensions matter to the UI: they drive the "this file is
        // large enough to risk the memory budget" warning.
        napi_value w = nullptr;
        napi_create_uint32(env, t->width_out, &w);
        napi_set_named_property(env, result, "width", w);
        napi_value h = nullptr;
        napi_create_uint32(env, t->height_out, &h);
        napi_set_named_property(env, result, "height", h);
        napi_resolve_deferred(env, t->deferred, result);
    } else {
        napi_value message = MakeString(env, t->err.empty() ? "render failed" : t->err);
        napi_value error = nullptr;
        napi_create_error(env, nullptr, message, &error);
        napi_value code = nullptr;
        napi_create_int32(env, t->code, &code);
        napi_set_named_property(env, error, "code", code);
        napi_reject_deferred(env, t->deferred, error);
    }

    napi_delete_async_work(env, t->work);
    delete t;
}

// Builds the promise, fills the task from `options`, and queues it.
napi_value StartRender(napi_env env, napi_value options, bool testPattern) {
    auto *task = new RenderTask();
    task->testPattern = testPattern;

    if (!GetStringProp(env, options, "dataDir", task->dataDir) ||
        !GetStringProp(env, options, "output", task->output) ||
        !GetStringProp(env, options, "film", task->film)) {
        delete task;
        napi_throw_type_error(env, nullptr, "options must contain dataDir, output and film");
        return nullptr;
    }
    GetOptionalStringProp(env, options, "paper", task->paper);
    if (testPattern) {
        if (!GetUint32Prop(env, options, "width", task->width)) task->width = 1024;
        if (!GetUint32Prop(env, options, "height", task->height)) task->height = 683;
    } else {
        if (!GetStringProp(env, options, "input", task->input)) {
            delete task;
            napi_throw_type_error(env, nullptr, "options.input is required");
            return nullptr;
        }
        GetOptionalStringProp(env, options, "params", task->params);
        GetOptionalStringProp(env, options, "border", task->border);
        GetOptionalStringProp(env, options, "exportOptions", task->output_spec);

        // Optional crop rectangle: {x, y, width, height, angle} as fractions
        // of the frame plus degrees. Absent means the whole frame.
        napi_value cropObj = nullptr;
        if (napi_get_named_property(env, options, "crop", &cropObj) == napi_ok &&
            cropObj != nullptr) {
            napi_valuetype t = napi_undefined;
            napi_typeof(env, cropObj, &t);
            if (t == napi_object) {
                double x = 0, y = 0, w = 1, h = 1, a = 0;
                GetDoubleProp(env, cropObj, "x", x);
                GetDoubleProp(env, cropObj, "y", y);
                GetDoubleProp(env, cropObj, "width", w);
                GetDoubleProp(env, cropObj, "height", h);
                GetDoubleProp(env, cropObj, "angle", a);
                if (w > 0.0 && h > 0.0) {
                    task->crop[0] = x;
                    task->crop[1] = y;
                    task->crop[2] = w;
                    task->crop[3] = h;
                    task->crop[4] = a;
                    task->hasCrop = true;
                }
            }
        }
    }

    napi_value promise = nullptr;
    napi_create_promise(env, &task->deferred, &promise);

    napi_value resourceName = MakeString(env, "spektrafilmRender");
    napi_create_async_work(env, nullptr, resourceName, ExecuteRender, CompleteRender, task,
                           &task->work);
    napi_queue_async_work(env, task->work);
    return promise;
}

// Solves the enlarger filter pack for the current film and paper.
napi_value SolveFilters(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "solveFilters(options) requires an object");
        return nullptr;
    }

    auto *task = new RenderTask();
    task->solve = true;
    if (!GetStringProp(env, argv[0], "dataDir", task->dataDir) ||
        !GetStringProp(env, argv[0], "input", task->input) ||
        !GetStringProp(env, argv[0], "film", task->film)) {
        delete task;
        napi_throw_type_error(env, nullptr, "options must contain dataDir, input and film");
        return nullptr;
    }
    GetOptionalStringProp(env, argv[0], "paper", task->paper);
    GetOptionalStringProp(env, argv[0], "params", task->params);

    napi_value cropObj = nullptr;
    if (napi_get_named_property(env, argv[0], "crop", &cropObj) == napi_ok && cropObj != nullptr) {
        napi_valuetype t = napi_undefined;
        napi_typeof(env, cropObj, &t);
        if (t == napi_object) {
            double x = 0, y = 0, w = 1, h = 1, a = 0;
            GetDoubleProp(env, cropObj, "x", x);
            GetDoubleProp(env, cropObj, "y", y);
            GetDoubleProp(env, cropObj, "width", w);
            GetDoubleProp(env, cropObj, "height", h);
            GetDoubleProp(env, cropObj, "angle", a);
            if (w > 0.0 && h > 0.0) {
                task->crop[0] = x;
                task->crop[1] = y;
                task->crop[2] = w;
                task->crop[3] = h;
                task->crop[4] = a;
                task->hasCrop = true;
            }
        }
    }

    napi_value promise = nullptr;
    napi_create_promise(env, &task->deferred, &promise);
    napi_value resourceName = MakeString(env, "spektrafilmSolve");
    napi_create_async_work(env, nullptr, resourceName, ExecuteRender, CompleteRender, task,
                           &task->work);
    napi_queue_async_work(env, task->work);
    return promise;
}

// --- module functions ------------------------------------------------------

napi_value GetVersion(napi_env env, napi_callback_info /*info*/) {
    return MakeString(env, sf_version());
}

// Returns the catalogue as a JSON string; ArkTS parses it. Building a JS object
// graph here would buy nothing and cost a lot of code.
napi_value GetCatalog(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 1) {
        napi_throw_type_error(env, nullptr, "getCatalog(dataDir) requires a path");
        return nullptr;
    }
    std::string dataDir;
    if (!GetStringProp(env, args[0], "path", dataDir)) {
        // Accept a bare string as well, for convenience.
        size_t len = 0;
        if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &len) != napi_ok) {
            napi_throw_type_error(env, nullptr, "getCatalog expects a string");
            return nullptr;
        }
        dataDir.resize(len + 1);
        size_t written = 0;
        napi_get_value_string_utf8(env, args[0], dataDir.data(), len + 1, &written);
        dataDir.resize(written);
    }

    char err[kErrCap];
    err[0] = '\0';
    int32_t need = sf_catalog(dataDir.c_str(), nullptr, 0, err, kErrCap);
    if (need < 0) {
        napi_throw_error(env, nullptr, err);
        return nullptr;
    }
    std::string json(static_cast<size_t>(need), '\0');
    int32_t written = sf_catalog(dataDir.c_str(), json.data(), json.size(), err, kErrCap);
    if (written < 0) {
        napi_throw_error(env, nullptr, err);
        return nullptr;
    }
    json.resize(static_cast<size_t>(written));
    return MakeString(env, json);
}

napi_value RenderFile(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "renderFile(options) requires an object");
        return nullptr;
    }
    return StartRender(env, args[0], false);
}

napi_value RenderTestPattern(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "renderTestPattern(options) requires an object");
        return nullptr;
    }
    return StartRender(env, args[0], true);
}

// Exporting a 33^3 LUT is a few hundred milliseconds of pipeline evaluation,
// not seconds, so this stays synchronous — the caller stores the path right
// away and there is no progress to report.
napi_value ExportLut(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "exportLut(options) requires an object");
        return nullptr;
    }

    std::string film, paper, dataDir, params, output;
    if (!GetStringProp(env, args[0], "film", film) ||
        !GetStringProp(env, args[0], "dataDir", dataDir) ||
        !GetStringProp(env, args[0], "output", output)) {
        napi_throw_type_error(env, nullptr, "options must contain film, dataDir and output");
        return nullptr;
    }
    GetOptionalStringProp(env, args[0], "paper", paper);
    GetOptionalStringProp(env, args[0], "params", params);

    uint32_t size = 33;
    if (!GetUint32Prop(env, args[0], "size", size)) {
        size = 33;
    }

    char err[kErrCap];
    err[0] = '\0';
    int32_t written = sf_export_lut(film.c_str(), Nullable(paper), dataDir.c_str(),
                                    Nullable(params), size, output.c_str(), err, kErrCap);
    if (written < 0) {
        napi_throw_error(env, nullptr, err);
        return nullptr;
    }
    napi_value result = nullptr;
    napi_create_int32(env, written, &result);
    return result;
}

// --- presets ---------------------------------------------------------------

// importPreset(text, dataDir, currentJson?) -> JSON
napi_value ImportPreset(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        napi_throw_type_error(env, nullptr, "importPreset(text, dataDir, currentJson?)");
        return nullptr;
    }
    std::string text, dataDir, current;
    if (!GetStringValue(env, args[0], text) || !GetStringValue(env, args[1], dataDir)) {
        napi_throw_type_error(env, nullptr, "importPreset needs string arguments");
        return nullptr;
    }
    if (argc >= 3) {
        GetStringValue(env, args[2], current);
    }
    const char *currentPtr = current.empty() ? nullptr : current.c_str();

    return JsonCall(env, [&](char *buf, size_t cap, char *err) {
        return sf_preset_import(text.c_str(), dataDir.c_str(), currentPtr, buf, cap, err, kErrCap);
    });
}

// mergeParams(baseJson, overJson) -> JSON
napi_value MergeParams(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        napi_throw_type_error(env, nullptr, "mergeParams(baseJson, overJson)");
        return nullptr;
    }
    std::string base, over;
    if (!GetStringValue(env, args[0], base) || !GetStringValue(env, args[1], over)) {
        napi_throw_type_error(env, nullptr, "mergeParams needs string arguments");
        return nullptr;
    }
    return JsonCall(env, [&](char *buf, size_t cap, char *err) {
        return sf_merge_params(base.c_str(), over.c_str(), buf, cap, err, kErrCap);
    });
}

// exportPreset({film, paper, params, dataDir, output}) -> bytes
napi_value ExportPreset(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "exportPreset(options) requires an object");
        return nullptr;
    }
    std::string film, paper, params, dataDir, output;
    if (!GetStringProp(env, args[0], "film", film) ||
        !GetStringProp(env, args[0], "paper", paper) ||
        !GetStringProp(env, args[0], "dataDir", dataDir) ||
        !GetStringProp(env, args[0], "output", output)) {
        napi_throw_type_error(env, nullptr, "options must contain film, paper, dataDir, output");
        return nullptr;
    }
    GetOptionalStringProp(env, args[0], "params", params);

    char err[kErrCap];
    err[0] = '\0';
    int32_t written = sf_preset_export(film.c_str(), paper.c_str(),
                                       params.empty() ? nullptr : params.c_str(),
                                       dataDir.c_str(), output.c_str(), err, kErrCap);
    if (written < 0) {
        napi_throw_error(env, nullptr, err);
        return nullptr;
    }
    napi_value result = nullptr;
    napi_create_int32(env, written, &result);
    return result;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"version", nullptr, GetVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getCatalog", nullptr, GetCatalog, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"renderFile", nullptr, RenderFile, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"solveFilters", nullptr, SolveFilters, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"renderTestPattern", nullptr, RenderTestPattern, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"exportLut", nullptr, ExportLut, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"importPreset", nullptr, ImportPreset, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"mergeParams", nullptr, MergeParams, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"exportPreset", nullptr, ExportPreset, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "spektrafilmoh",
    .nm_priv = nullptr,
    .reserved = {0},
};

}  // namespace

extern "C" __attribute__((constructor)) void RegisterSpektrafilmModule(void) {
    napi_module_register(&g_module);
}
