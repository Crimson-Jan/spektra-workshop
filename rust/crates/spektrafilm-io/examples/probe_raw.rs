//! 诊断用：把一个 RAW 文件丢给 rawler，看它能不能解、报什么错。
use rawler::decoders::RawDecodeParams;
use rawler::rawsource::RawSource;
use std::time::Instant;

fn main() {
    let path = match std::env::args().nth(1) {
        Some(p) => p,
        None => {
            eprintln!("用法: probe_raw <file.ARW>");
            return;
        }
    };
    let bytes = match std::fs::read(&path) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("读取失败: {e}");
            return;
        }
    };
    println!("文件: {path}");
    println!("大小: {:.1} MB", bytes.len() as f64 / 1048576.0);

    let src = RawSource::new_from_slice(&bytes);
    let params = RawDecodeParams::default();
    let t0 = Instant::now();
    match rawler::decode(&src, &params) {
        Ok(img) => {
            println!("解码成功 ({:.0} ms)", t0.elapsed().as_millis() as f64);
            println!("  make: {:?}", img.make);
            println!("  model: {:?}", img.model);
        }
        Err(e) => {
            println!("解码失败 ({:.0} ms)", t0.elapsed().as_millis() as f64);
            println!("  错误: {:?}", e);
        }
    }
}
