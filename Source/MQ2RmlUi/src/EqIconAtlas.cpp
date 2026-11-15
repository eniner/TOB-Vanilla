#include <mq/Plugin.h>   // MacroQuest plugin API (MQ2Main, eqlib, PLUGIN_API)
#include "EqIconAtlas.h"

#include <windows.h>

#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <unordered_map>
#include <vector>

// stbi_load lives in RenderInterface_DX11.cpp (STB_IMAGE_IMPLEMENTATION).
extern "C" unsigned char* stbi_load_from_memory(unsigned char const* buffer, int len, int* x, int* y, int* channels_in_file, int desired_channels);
extern "C" void stbi_image_free(void* retval_from_stbi_load);

#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#include "stb_image_write.h"

namespace fs = std::filesystem;

namespace EqIcon {
namespace {

std::mutex g_mutex;
std::string g_uiFilesPath;
std::string g_returnPath;

// Minimal CPU DDS decode for EQ UI sheets (uncompressed BGRA / DXT1 / DXT5).
#pragma pack(push, 1)
struct DdsPixelFormat
{
	uint32_t size, flags, fourCC, rgbBitCount, rMask, gMask, bMask, aMask;
};
struct DdsHeader
{
	uint32_t size, flags, height, width, pitchOrLinearSize, depth, mipMapCount;
	uint32_t reserved1[11];
	DdsPixelFormat pf;
	uint32_t caps, caps2, caps3, caps4, reserved2;
};
#pragma pack(pop)

constexpr uint32_t FourCC(char a, char b, char c, char d)
{
	return (uint32_t)(uint8_t)a | ((uint32_t)(uint8_t)b << 8) | ((uint32_t)(uint8_t)c << 16) | ((uint32_t)(uint8_t)d << 24);
}

void DecodeDXT1Block(const uint8_t block[8], uint8_t out[16 * 4])
{
	const uint16_t c0 = (uint16_t)(block[0] | (block[1] << 8));
	const uint16_t c1 = (uint16_t)(block[2] | (block[3] << 8));
	auto expand = [](uint16_t c, uint8_t rgb[3]) {
		rgb[0] = (uint8_t)(((c >> 11) & 31) * 255 / 31);
		rgb[1] = (uint8_t)(((c >> 5) & 63) * 255 / 63);
		rgb[2] = (uint8_t)((c & 31) * 255 / 31);
	};
	uint8_t c[4][4];
	expand(c0, c[0]); c[0][3] = 255;
	expand(c1, c[1]); c[1][3] = 255;
	if (c0 > c1)
	{
		for (int i = 0; i < 3; ++i) { c[2][i] = (uint8_t)((2 * c[0][i] + c[1][i]) / 3); c[3][i] = (uint8_t)((c[0][i] + 2 * c[1][i]) / 3); }
		c[2][3] = c[3][3] = 255;
	}
	else
	{
		for (int i = 0; i < 3; ++i) { c[2][i] = (uint8_t)((c[0][i] + c[1][i]) / 2); c[3][i] = 0; }
		c[2][3] = 255; c[3][3] = 0;
	}
	uint32_t bits = block[4] | (block[5] << 8) | (block[6] << 16) | (block[7] << 24);
	for (int i = 0; i < 16; ++i)
	{
		const int idx = (bits >> (i * 2)) & 3;
		out[i * 4 + 0] = c[idx][0];
		out[i * 4 + 1] = c[idx][1];
		out[i * 4 + 2] = c[idx][2];
		out[i * 4 + 3] = c[idx][3];
	}
}

void DecodeDXT5Block(const uint8_t block[16], uint8_t out[16 * 4])
{
	DecodeDXT1Block(block + 8, out);
	const uint8_t a0 = block[0], a1 = block[1];
	uint8_t alphas[8];
	alphas[0] = a0; alphas[1] = a1;
	if (a0 > a1)
		for (int i = 1; i <= 6; ++i) alphas[i + 1] = (uint8_t)(((7 - i) * a0 + i * a1) / 7);
	else
	{
		for (int i = 1; i <= 4; ++i) alphas[i + 1] = (uint8_t)(((5 - i) * a0 + i * a1) / 5);
		alphas[6] = 0; alphas[7] = 255;
	}
	uint64_t abits = 0;
	for (int i = 0; i < 6; ++i) abits |= (uint64_t)block[2 + i] << (8 * i);
	for (int i = 0; i < 16; ++i)
		out[i * 4 + 3] = alphas[(abits >> (i * 3)) & 7];
}

bool LoadDdsRGBA(const std::vector<uint8_t>& bytes, std::vector<uint8_t>& rgba, int& w, int& h)
{
	if (bytes.size() < 4 + sizeof(DdsHeader))
		return false;
	if (std::memcmp(bytes.data(), "DDS ", 4) != 0)
		return false;
	DdsHeader hdr{};
	std::memcpy(&hdr, bytes.data() + 4, sizeof(hdr));
	if (hdr.size != 124 || hdr.width == 0 || hdr.height == 0)
		return false;
	w = (int)hdr.width;
	h = (int)hdr.height;
	const uint8_t* data = bytes.data() + 4 + sizeof(DdsHeader);
	const size_t dataSize = bytes.size() - (4 + sizeof(DdsHeader));
	rgba.assign((size_t)w * (size_t)h * 4, 0);

	const bool dxt1 = hdr.pf.flags & 0x4 && hdr.pf.fourCC == FourCC('D', 'X', 'T', '1');
	const bool dxt5 = hdr.pf.flags & 0x4 && (hdr.pf.fourCC == FourCC('D', 'X', 'T', '5') || hdr.pf.fourCC == FourCC('D', 'X', 'T', '3'));
	if (dxt1 || dxt5)
	{
		const int blockBytes = dxt1 ? 8 : 16;
		const int blocksX = (w + 3) / 4;
		const int blocksY = (h + 3) / 4;
		if (dataSize < (size_t)blocksX * blocksY * blockBytes)
			return false;
		uint8_t blockPix[16 * 4];
		for (int by = 0; by < blocksY; ++by)
		{
			for (int bx = 0; bx < blocksX; ++bx)
			{
				const uint8_t* block = data + ((size_t)by * blocksX + bx) * blockBytes;
				if (dxt1) DecodeDXT1Block(block, blockPix);
				else DecodeDXT5Block(block, blockPix);
				for (int py = 0; py < 4; ++py)
				{
					const int y = by * 4 + py;
					if (y >= h) break;
					for (int px = 0; px < 4; ++px)
					{
						const int x = bx * 4 + px;
						if (x >= w) break;
						std::memcpy(rgba.data() + ((size_t)y * w + x) * 4, blockPix + (py * 4 + px) * 4, 4);
					}
				}
			}
		}
		return true;
	}

	// Uncompressed 32-bit BGRA / RGBA
	if (hdr.pf.rgbBitCount == 32 && dataSize >= (size_t)w * h * 4)
	{
		const bool bgra = hdr.pf.bMask == 0x000000FF;
		for (int i = 0; i < w * h; ++i)
		{
			const uint8_t* s = data + i * 4;
			uint8_t* d = rgba.data() + i * 4;
			if (bgra) { d[0] = s[2]; d[1] = s[1]; d[2] = s[0]; d[3] = s[3]; }
			else { d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = s[3]; }
		}
		return true;
	}
	return false;
}

std::string DetectUiFilesPath()
{
	if (!g_uiFilesPath.empty())
		return g_uiFilesPath;

	char modulePath[MAX_PATH] = {};
	HMODULE eq = GetModuleHandleA("eqgame.exe");
	if (eq && GetModuleFileNameA(eq, modulePath, MAX_PATH))
	{
		fs::path p = fs::path(modulePath).parent_path() / "uifiles" / "default";
		if (fs::exists(p / "dragitem1.dds"))
			return p.string();
	}

	if (GetModuleFileNameA(nullptr, modulePath, MAX_PATH))
	{
		fs::path p = fs::path(modulePath).parent_path() / "uifiles" / "default";
		if (fs::exists(p / "dragitem1.dds"))
			return p.string();
	}

	// (Developer-machine fallback paths removed for the public build; rml_set_uifiles_path() overrides.)

	return {};
}

std::string NormalizeSlashes(std::string p)
{
	for (char& c : p)
		if (c == '\\')
			c = '/';
	return p;
}

void CellToXY(int localCell, bool vertical, int& x, int& y)
{
	const int cols = kCellsPerSide;
	const int rows = kCellsPerSide;
	int col = 0, row = 0;
	if (vertical)
	{
		col = localCell / rows;
		row = localCell % rows;
	}
	else
	{
		row = localCell / cols;
		col = localCell % cols;
	}
	x = col * kCellSize;
	y = row * kCellSize;
}

int ResolveCell(const char* kind, int id)
{
	if (!kind)
		return -1;
	if (_stricmp(kind, "item") == 0)
	{
		if (id <= 0)
			return -1;
		return (id >= kItemIconOffset) ? (id - kItemIconOffset) : id;
	}
	if (_stricmp(kind, "itemcell") == 0)
		return id;
	if (_stricmp(kind, "spell") == 0)
		return id;
	return -1;
}

bool IsItemKind(const char* kind)
{
	return kind && (_stricmp(kind, "item") == 0 || _stricmp(kind, "itemcell") == 0);
}

std::string SheetPath(const char* kind, int sheetIndex)
{
	const std::string root = DetectUiFilesPath();
	if (root.empty() || sheetIndex < 0)
		return {};

	char name[64];
	if (IsItemKind(kind))
		sprintf_s(name, "dragitem%d.dds", sheetIndex + 1);
	else
		sprintf_s(name, "Spells%02d.tga", sheetIndex + 1);

	fs::path p = fs::path(root) / name;
	if (!fs::exists(p))
		return {};
	return p.string();
}

bool LoadSheetRGBA(const std::string& path, std::vector<uint8_t>& rgba, int& w, int& h)
{
	rgba.clear();
	w = h = 0;
	if (path.empty())
		return false;

	std::ifstream file(path, std::ios::binary);
	if (!file)
		return false;
	file.seekg(0, std::ios::end);
	const std::streamoff len = file.tellg();
	if (len <= 0)
		return false;
	file.seekg(0, std::ios::beg);
	std::vector<uint8_t> bytes((size_t)len);
	file.read(reinterpret_cast<char*>(bytes.data()), len);

	if (bytes.size() >= 4 && std::memcmp(bytes.data(), "DDS ", 4) == 0)
		return LoadDdsRGBA(bytes, rgba, w, h);

	int channels = 0;
	unsigned char* pixels = stbi_load_from_memory(bytes.data(), (int)bytes.size(), &w, &h, &channels, 4);
	if (!pixels)
		return false;
	rgba.assign(pixels, pixels + (size_t)w * (size_t)h * 4);
	stbi_image_free(pixels);
	return true;
}

struct SheetCache
{
	std::vector<uint8_t> rgba;
	int w = 0;
	int h = 0;
};

std::unordered_map<std::string, SheetCache> g_sheets;

const SheetCache* GetSheet(const char* kind, int sheetIndex)
{
	const std::string path = SheetPath(kind, sheetIndex);
	if (path.empty())
		return nullptr;
	auto it = g_sheets.find(path);
	if (it != g_sheets.end())
		return &it->second;

	SheetCache cache;
	if (!LoadSheetRGBA(path, cache.rgba, cache.w, cache.h))
		return nullptr;
	auto [ins, _] = g_sheets.emplace(path, std::move(cache));
	return &ins->second;
}

std::string DefaultExportPath(const char* kind, int id)
{
	std::string root = mq::gPathMQRoot;
	if (root.empty())
		root = ".";
	fs::path dir = fs::path(root) / "lua" / "rmlui" / "icons" / "cache";
	std::error_code ec;
	fs::create_directories(dir, ec);
	char file[64];
	sprintf_s(file, "%s_%d.png", kind && *kind ? kind : "icon", id);
	return NormalizeSlashes((dir / file).string());
}

void StbiWriteToVector(void* context, void* data, int size)
{
	auto* out = static_cast<std::vector<uint8_t>*>(context);
	const auto* bytes = static_cast<const uint8_t*>(data);
	out->insert(out->end(), bytes, bytes + size);
}

} // namespace

void SetUiFilesPath(const char* path)
{
	std::lock_guard lock(g_mutex);
	g_uiFilesPath = path ? NormalizeSlashes(path) : std::string{};
	g_sheets.clear();
}

std::string GetUiFilesPath()
{
	std::lock_guard lock(g_mutex);
	return DetectUiFilesPath();
}

bool ParseEqUrl(const std::string& source, std::string& kindOut, int& idOut)
{
	// eq://item/1234  or  eq:item/1234
	std::string s = source;
	if (s.rfind("eq://", 0) == 0)
		s = s.substr(5);
	else if (s.rfind("eq:", 0) == 0)
		s = s.substr(3);
	else
		return false;

	const auto slash = s.find('/');
	if (slash == std::string::npos || slash == 0)
		return false;
	kindOut = s.substr(0, slash);
	idOut = atoi(s.c_str() + slash + 1);
	return !kindOut.empty();
}

bool Sample(const char* kind, int id, std::vector<uint8_t>& rgbaOut, int& w, int& h)
{
	std::lock_guard lock(g_mutex);
	rgbaOut.clear();
	w = h = 0;

	const int cell = ResolveCell(kind, id);
	if (cell < 0)
		return false;

	const int sheetIndex = cell / kCellsPerSheet;
	const int localCell = cell % kCellsPerSheet;
	const bool vertical = IsItemKind(kind); // A_DragItem Vertical=true; A_SpellIcons Vertical=false

	const SheetCache* sheet = GetSheet(kind, sheetIndex);
	if (!sheet || sheet->w < kCellSize || sheet->h < kCellSize)
		return false;

	int x = 0, y = 0;
	CellToXY(localCell, vertical, x, y);
	if (x + kCellSize > sheet->w || y + kCellSize > sheet->h)
		return false;

	w = kCellSize;
	h = kCellSize;
	rgbaOut.resize((size_t)w * (size_t)h * 4);
	for (int row = 0; row < kCellSize; ++row)
	{
		const uint8_t* src = sheet->rgba.data() + ((size_t)(y + row) * (size_t)sheet->w + (size_t)x) * 4;
		uint8_t* dst = rgbaOut.data() + (size_t)row * (size_t)w * 4;
		memcpy(dst, src, (size_t)kCellSize * 4);
	}
	return true;
}

std::string ExportPng(const char* kind, int id, const char* outPath)
{
	std::vector<uint8_t> rgba;
	int w = 0, h = 0;
	if (!Sample(kind, id, rgba, w, h))
		return {};

	std::string path = (outPath && *outPath) ? NormalizeSlashes(outPath) : DefaultExportPath(kind, id);
	fs::path p(path);
	std::error_code ec;
	fs::create_directories(p.parent_path(), ec);

	std::vector<uint8_t> png;
	if (!stbi_write_png_to_func(&StbiWriteToVector, &png, w, h, 4, rgba.data(), w * 4))
		return {};

	std::ofstream file(path, std::ios::binary);
	if (!file)
		return {};
	file.write(reinterpret_cast<const char*>(png.data()), (std::streamsize)png.size());
	return path;
}

std::string IconSrc(const char* kind, int id, bool preferFile)
{
	const char* k = (kind && *kind) ? kind : "item";
	if (preferFile)
	{
		std::string path = ExportPng(k, id, nullptr);
		return path;
	}

	std::vector<uint8_t> rgba;
	int w = 0, h = 0;
	if (Sample(k, id, rgba, w, h))
	{
		char buf[64];
		sprintf_s(buf, "eq://%s/%d", k, id);
		return buf;
	}

	return ExportPng(k, id, nullptr);
}

} // namespace EqIcon
