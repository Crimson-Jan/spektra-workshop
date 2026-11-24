export interface FilmChoiceInfo {
  title: string;
  detail: string;
  artPath: string;
}

export const FILM_CHOICES: Map<string, FilmChoiceInfo> = new Map<string, FilmChoiceInfo>([
  ['kodak_portra_160', { title: 'Portra 160', detail: '彩色负片', artPath: 'film-stocks/kodak_portra_160.webp' }],
  ['kodak_portra_400', { title: 'Portra 400', detail: '彩色负片', artPath: 'film-stocks/kodak_portra_400.webp' }],
  ['kodak_portra_800', { title: 'Portra 800', detail: '彩色负片', artPath: 'film-stocks/kodak_portra_800.webp' }],
  ['kodak_gold_200', { title: 'Gold 200', detail: '彩色负片', artPath: 'film-stocks/kodak_gold_200.webp' }],
  ['kodak_portra_800_push1', { title: 'Portra 800 · Push +1', detail: '彩色负片', artPath: 'film-stocks/kodak_portra_800.webp' }],
  ['kodak_portra_800_push2', { title: 'Portra 800 · Push +2', detail: '彩色负片', artPath: 'film-stocks/kodak_portra_800.webp' }],
  ['kodak_ektar_100', { title: 'Ektar 100', detail: '彩色负片', artPath: 'film-stocks/kodak_ektar_100.webp' }],
  ['kodak_ultramax_400', { title: 'Ultramax 400', detail: '彩色负片', artPath: 'film-stocks/kodak_ultramax_400.webp' }],
  ['fujifilm_c200', { title: 'Fujifilm C200', detail: '彩色负片', artPath: 'film-stocks/fujifilm_c200.webp' }],
  ['fujifilm_pro_400h', { title: 'Fujifilm Pro 400H', detail: '彩色负片', artPath: 'film-stocks/fujifilm_pro_400h.webp' }],
  ['fujifilm_xtra_400', { title: 'Fujifilm X-Tra 400', detail: '彩色负片', artPath: 'film-stocks/fujifilm_xtra_400.webp' }],
  ['kodak_trix400_d76_8min', { title: 'Tri-X 400', detail: '黑白负片', artPath: 'film-stocks/kodak_trix400_d76_8min.webp' }],
  ['fujifilm_provia_100f', { title: 'Provia 100F', detail: '彩色正片', artPath: 'film-stocks/fujifilm_provia_100f.webp' }],
  ['fujifilm_velvia_100', { title: 'Velvia 100', detail: '彩色正片', artPath: 'film-stocks/fujifilm_velvia_100.webp' }],
  ['kodak_ektachrome_100', { title: 'Ektachrome 100', detail: '彩色正片', artPath: 'film-stocks/kodak_ektachrome_100.webp' }],
  ['kodak_kodachrome_64', { title: 'Kodachrome 64', detail: '彩色正片', artPath: 'film-stocks/kodak_kodachrome_64.webp' }],
  ['kodak_vision3_50d', { title: 'Vision3 50D', detail: '彩色电影负片', artPath: 'film-stocks/kodak_vision3_50d.webp' }],
  ['kodak_vision3_250d', { title: 'Vision3 250D', detail: '彩色电影负片', artPath: 'film-stocks/kodak_vision3_250d.webp' }],
  ['kodak_vision3_200t', { title: 'Vision3 200T', detail: '彩色电影负片', artPath: 'film-stocks/kodak_vision3_200t.webp' }],
  ['kodak_vision3_500t', { title: 'Vision3 500T', detail: '彩色电影负片', artPath: 'film-stocks/kodak_vision3_500t.webp' }],
  ['kodak_verita_200d', { title: 'Verita 200D', detail: '彩色电影负片', artPath: 'film-stocks/kodak_verita_200d.webp' }],
  ['kodak_doublex', { title: 'Double-X 5222', detail: '黑白电影负片', artPath: 'film-stocks/kodak_doublex.webp' }],
  ['kodak_trix', { title: 'Tri-X 7266', detail: '黑白反转电影片', artPath: 'film-stocks/kodak_trix.webp' }],
  ['kodak_2302', { title: 'Print Film 2302', detail: '黑白拷贝片', artPath: 'film-stocks/kodak_2302.webp' }],
  ['kodak_2383', { title: 'Vision 2383', detail: '彩色拷贝片', artPath: 'film-stocks/kodak_2383.webp' }],
  ['kodak_2393', { title: 'Vision Premier 2393', detail: '彩色拷贝片', artPath: 'film-stocks/kodak_2393.webp' }]
]);
