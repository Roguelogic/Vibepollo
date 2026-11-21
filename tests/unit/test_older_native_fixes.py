"""Compile actual macOS VideoToolbox encoder definition with deterministic seams."""
from pathlib import Path
import argparse, subprocess, tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[2])
parser.add_argument('--compiler', default='clang++')
parser.add_argument('--only', choices=['videotoolbox'], action='append')
args = parser.parse_args()
root = args.repo
video = (root / 'src/video.cpp').read_text()
start = video.index('  encoder_t videotoolbox {')
end = video.index('\n  };\n', start) + len('\n  };\n')
block = video[start:end]

program = r'''
#include <cassert>
#include <memory>
#include <string>
#include <string_view>
#include <variant>
#include <vector>
using namespace std::literals;
namespace platf {
enum class mem_type_e { videotoolbox };
enum class pix_fmt_e { nv12, p010, ayuv, yuv444p16 };
}
struct encoder_platform_formats_vt {
  platf::mem_type_e dev_type;
  platf::pix_fmt_e pix_fmt_8bit, pix_fmt_10bit, pix_fmt_yuv444_8bit, pix_fmt_yuv444_10bit;
  encoder_platform_formats_vt(
    platf::mem_type_e d, platf::pix_fmt_e p8, platf::pix_fmt_e p10,
    platf::pix_fmt_e y8, platf::pix_fmt_e y10)
    : dev_type(d), pix_fmt_8bit(p8), pix_fmt_10bit(p10),
      pix_fmt_yuv444_8bit(y8), pix_fmt_yuv444_10bit(y10) {}
};
struct option_t { std::string name; std::variant<int, int*, std::string> value; };
struct codec_t {
  std::vector<option_t> common_options, sdr_options, hdr_options, yuv444_sdr_options, yuv444_hdr_options, fallback_options;
  std::string name;
};
enum { DEFAULT = 0, PARALLEL_ENCODING = 2, YUV444_SUPPORT = 4 };
struct encoder_t {
  std::string_view name;
  std::unique_ptr<encoder_platform_formats_vt> formats;
  codec_t av1, hevc, h264;
  int flags;
};
@BLOCK@
int main() {
  assert(videotoolbox.name == "videotoolbox"sv);
  assert(videotoolbox.av1.name == "av1_vt");
  assert(videotoolbox.hevc.name == "hevc_vt");
  assert(videotoolbox.h264.name == "h264_vt");
  assert((videotoolbox.flags & PARALLEL_ENCODING) != 0);
  assert((videotoolbox.flags & YUV444_SUPPORT) != 0);
  assert(videotoolbox.formats != nullptr);
  assert(videotoolbox.formats->pix_fmt_8bit == platf::pix_fmt_e::nv12);
  assert(videotoolbox.formats->pix_fmt_10bit == platf::pix_fmt_e::p010);
}
'''.replace('@BLOCK@', block)

with tempfile.TemporaryDirectory(prefix='small-native-') as tmp:
    cpp = Path(tmp) / 'videotoolbox.cpp'
    cpp.write_text(program)
    binary = Path(tmp) / 'videotoolbox'
    subprocess.run([args.compiler, '-std=c++23', '-Wall', '-Wextra', '-Werror', str(cpp), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
    print('PASS: production videotoolbox', flush=True)
