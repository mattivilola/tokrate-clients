//! Tray icon: the default app icon, or a provider letter badge drawn at runtime (no font, no assets).
use tokrate_core::ProviderBadge;

const SIZE: u32 = 64;
const CENTER: f32 = 32.0;
const RADIUS: f32 = 31.0;
const STROKE_HALF: f32 = 3.5;
const SUBSAMPLES: u32 = 4;
type Rgb = [u8; 3];
type Segment = ((f32, f32), (f32, f32));

const TERRACOTTA: Rgb = [0xD9, 0x77, 0x57];
const GREEN: Rgb = [0x10, 0xA3, 0x7F];
const GREY: Rgb = [0x8A, 0x9B, 0xA3];
const WHITE: Rgb = [0xFF, 0xFF, 0xFF];
const BLACK: Rgb = [0x00, 0x00, 0x00];

const LETTER_A: [Segment; 3] = [
    ((32.0, 16.0), (21.0, 48.0)),
    ((32.0, 16.0), (43.0, 48.0)),
    ((24.5, 39.0), (39.5, 39.0)),
];
const LETTER_X: [Segment; 2] = [((22.0, 18.0), (42.0, 46.0)), ((42.0, 18.0), (22.0, 46.0))];
const LETTER_O_RADIUS: f32 = 14.0;

/// The packaged tray icon, shown whenever no provider badge applies.
pub fn default_icon() -> tauri::Result<tauri::image::Image<'static>> {
    tauri::image::Image::from_bytes(include_bytes!("../icons/icon.png"))
}

fn segment_distance((x, y): (f32, f32), ((ax, ay), (bx, by)): Segment) -> f32 {
    let (dx, dy) = (bx - ax, by - ay);
    let t = (((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy)).clamp(0.0, 1.0);
    (x - (ax + t * dx)).hypot(y - (ay + t * dy))
}

/// Distance from a point to the letter's centre line, `None` for a badge without a letter.
fn letter_distance(letter: Option<char>, point: (f32, f32)) -> Option<f32> {
    let nearest = |segments: &[Segment]| {
        segments
            .iter()
            .map(|segment| segment_distance(point, *segment))
            .fold(f32::INFINITY, f32::min)
    };
    match letter? {
        'A' => Some(nearest(&LETTER_A)),
        'X' => Some(nearest(&LETTER_X)),
        'O' => Some(((point.0 - CENTER).hypot(point.1 - CENTER) - LETTER_O_RADIUS).abs()),
        _ => None,
    }
}

fn colors(badge: ProviderBadge, dark: bool) -> (Rgb, Rgb) {
    match badge {
        ProviderBadge::Anthropic => (TERRACOTTA, WHITE),
        ProviderBadge::OpenAi => (GREEN, WHITE),
        ProviderBadge::Xai if dark => (WHITE, BLACK),
        ProviderBadge::Xai => (BLACK, WHITE),
        ProviderBadge::Unknown => (GREY, WHITE),
    }
}

/// Renders a 64x64 straight-alpha RGBA circle with the provider letter, antialiased by supersampling.
pub fn render_badge(badge: ProviderBadge, dark: bool) -> (Vec<u8>, u32, u32) {
    let (background, foreground) = colors(badge, dark);
    let letter = badge.letter();
    let mut rgba = Vec::with_capacity((SIZE * SIZE * 4) as usize);
    for py in 0..SIZE {
        for px in 0..SIZE {
            let (mut inside, mut inked) = (0u32, 0u32);
            for sy in 0..SUBSAMPLES {
                for sx in 0..SUBSAMPLES {
                    let step =
                        |cell: u32, sub: u32| cell as f32 + (sub as f32 + 0.5) / SUBSAMPLES as f32;
                    let point = (step(px, sx), step(py, sy));
                    if (point.0 - CENTER).hypot(point.1 - CENTER) <= RADIUS {
                        inside += 1;
                        if letter_distance(letter, point).is_some_and(|d| d <= STROKE_HALF) {
                            inked += 1;
                        }
                    }
                }
            }
            if inside == 0 {
                rgba.extend_from_slice(&[0, 0, 0, 0]);
                continue;
            }
            let mix = |channel: usize| {
                let total = background[channel] as u32 * (inside - inked)
                    + foreground[channel] as u32 * inked;
                ((total + inside / 2) / inside) as u8
            };
            let coverage = (inside * 255 + SUBSAMPLES * SUBSAMPLES / 2) / (SUBSAMPLES * SUBSAMPLES);
            rgba.extend_from_slice(&[mix(0), mix(1), mix(2), coverage as u8]);
        }
    }
    (rgba, SIZE, SIZE)
}

#[cfg(test)]
mod tests {
    use super::*;
    const ALL: [ProviderBadge; 4] = [
        ProviderBadge::Anthropic,
        ProviderBadge::OpenAi,
        ProviderBadge::Xai,
        ProviderBadge::Unknown,
    ];
    fn pixel(rgba: &[u8], x: u32, y: u32) -> [u8; 4] {
        let at = ((y * SIZE + x) * 4) as usize;
        rgba[at..at + 4].try_into().unwrap()
    }
    fn opaque(color: Rgb) -> [u8; 4] {
        [color[0], color[1], color[2], 255]
    }
    #[test]
    fn badges_are_64_square_rgba_with_transparent_corners() {
        for badge in ALL {
            for dark in [false, true] {
                let (rgba, width, height) = render_badge(badge, dark);
                assert_eq!((width, height), (64, 64));
                assert_eq!(rgba.len(), 64 * 64 * 4);
                for (x, y) in [(0, 0), (63, 0), (0, 63), (63, 63)] {
                    assert_eq!(pixel(&rgba, x, y)[3], 0);
                }
                assert_eq!(pixel(&rgba, 32, 2)[3], 255);
            }
        }
    }
    #[test]
    fn circle_background_uses_the_brand_colour_and_letters_are_drawn_in_contrast() {
        let (a, ..) = render_badge(ProviderBadge::Anthropic, false);
        let (o, ..) = render_badge(ProviderBadge::OpenAi, false);
        let (x, ..) = render_badge(ProviderBadge::Xai, false);
        let (unknown, ..) = render_badge(ProviderBadge::Unknown, false);
        // The centre of "A" and "O" is background; the centre of "X" is where its strokes cross.
        assert_eq!(pixel(&a, 32, 32), opaque(TERRACOTTA));
        assert_eq!(pixel(&o, 32, 32), opaque(GREEN));
        assert_eq!(pixel(&x, 32, 32), opaque(WHITE));
        assert_eq!(pixel(&x, 32, 6), opaque(BLACK));
        assert_eq!(pixel(&unknown, 32, 32), opaque(GREY));
        // Letter strokes: left leg of "A", crossbar of "A", ring of "O", diagonal of "X".
        assert_eq!(pixel(&a, 26, 32), opaque(WHITE));
        assert_eq!(pixel(&a, 32, 39), opaque(WHITE));
        assert_eq!(pixel(&o, 18, 32), opaque(WHITE));
        assert_eq!(pixel(&x, 27, 25), opaque(WHITE));
    }
    #[test]
    fn unknown_provider_is_a_plain_dot_without_a_letter() {
        let (rgba, ..) = render_badge(ProviderBadge::Unknown, false);
        assert!(rgba.chunks(4).all(|p| p[3] == 0 || p[..3] == GREY));
    }
    #[test]
    fn xai_inverts_with_the_theme() {
        let (light, ..) = render_badge(ProviderBadge::Xai, false);
        let (dark, ..) = render_badge(ProviderBadge::Xai, true);
        assert_ne!(light, dark);
        assert_eq!(pixel(&dark, 32, 6), opaque(WHITE));
        assert_eq!(pixel(&dark, 32, 32), opaque(BLACK));
        for badge in [ProviderBadge::Anthropic, ProviderBadge::OpenAi] {
            assert_eq!(render_badge(badge, false), render_badge(badge, true));
        }
    }
    #[test]
    fn edges_are_antialiased() {
        let (rgba, ..) = render_badge(ProviderBadge::Anthropic, false);
        assert!(rgba.chunks(4).any(|p| p[3] > 0 && p[3] < 255));
    }

    fn crc32(bytes: &[u8]) -> u32 {
        let mut crc = !0u32;
        for byte in bytes {
            crc ^= *byte as u32;
            for _ in 0..8 {
                crc = if crc & 1 == 1 {
                    (crc >> 1) ^ 0xEDB8_8320
                } else {
                    crc >> 1
                };
            }
        }
        !crc
    }
    fn png_chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
        out.extend_from_slice(&(data.len() as u32).to_be_bytes());
        let body = [kind.as_slice(), data].concat();
        out.extend_from_slice(&body);
        out.extend_from_slice(&crc32(&body).to_be_bytes());
    }
    /// Minimal PNG: 8-bit RGBA, filter 0, zlib stored (uncompressed) blocks.
    fn encode_png(rgba: &[u8], width: u32, height: u32) -> Vec<u8> {
        let raw: Vec<u8> = rgba
            .chunks((width * 4) as usize)
            .flat_map(|row| std::iter::once(0u8).chain(row.iter().copied()))
            .collect();
        let (mut a, mut b) = (1u32, 0u32);
        for byte in &raw {
            a = (a + *byte as u32) % 65521;
            b = (b + a) % 65521;
        }
        let mut zlib = vec![0x78, 0x01];
        let blocks: Vec<&[u8]> = raw.chunks(65535).collect();
        for (index, block) in blocks.iter().enumerate() {
            zlib.push((index + 1 == blocks.len()) as u8);
            zlib.extend_from_slice(&(block.len() as u16).to_le_bytes());
            zlib.extend_from_slice(&(!(block.len() as u16)).to_le_bytes());
            zlib.extend_from_slice(block);
        }
        zlib.extend_from_slice(&((b << 16) | a).to_be_bytes());
        let mut header = [width.to_be_bytes(), height.to_be_bytes()].concat();
        header.extend_from_slice(&[8, 6, 0, 0, 0]);
        let mut png = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
        png_chunk(&mut png, b"IHDR", &header);
        png_chunk(&mut png, b"IDAT", &zlib);
        png_chunk(&mut png, b"IEND", &[]);
        png
    }
    /// `TOKRATE_DUMP_BADGES=/some/dir cargo test dump_badges -- --ignored` writes every badge as PNG.
    #[test]
    #[ignore]
    fn dump_badges() {
        let Some(dir) = std::env::var_os("TOKRATE_DUMP_BADGES") else {
            return;
        };
        let dir = std::path::PathBuf::from(dir);
        std::fs::create_dir_all(&dir).unwrap();
        for badge in ALL {
            for (dark, theme) in [(false, "light"), (true, "dark")] {
                let (rgba, width, height) = render_badge(badge, dark);
                let name = format!("{}-{theme}.png", badge.label().replace(' ', "-"));
                std::fs::write(dir.join(name), encode_png(&rgba, width, height)).unwrap();
            }
        }
    }
}
