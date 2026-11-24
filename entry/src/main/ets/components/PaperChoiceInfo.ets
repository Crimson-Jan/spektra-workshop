interface PaperChoiceInfo {
  title: string;
  detail: string;
}

export const PAPER_CHOICES: Map<string, PaperChoiceInfo> = new Map<string, PaperChoiceInfo>([
  ['fujifilm_crystal_archive_typeii', { title: 'Crystal Archive Type II', detail: '富士 · 彩色相纸' }],
  ['kodak_ektacolor_edge', { title: 'Ektacolor Edge', detail: '柯达 · 彩色相纸' }],
  ['kodak_portra_endura', { title: 'Portra Endura', detail: '柯达 · 彩色相纸' }],
  ['kodak_supra_endura', { title: 'Supra Endura', detail: '柯达 · 彩色相纸' }],
  ['kodak_ultra_endura', { title: 'Ultra Endura', detail: '柯达 · 彩色相纸' }],
  ['kodak_endura_premier', { title: 'Endura Premier', detail: '柯达 · 彩色相纸' }],
  ['ilford_mgrc_deluxe_grade2', { title: 'Multigrade RC Deluxe', detail: '黑白相纸 · 2 号' }]
]);
