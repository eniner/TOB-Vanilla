#pragma once

#include <cstdint>
#include <string>
#include <vector>

// Sample EverQuest UI icon atlases (A_DragItem / A_SpellIcons) into RGBA pixels for RmlUi.
// Primary <img> source:  eq://item/<Icon()>   eq://itemcell/<cell>   eq://spell/<SpellIcon()>
// Fallback: export a PNG under lua/rmlui/icons/cache/ and use that file path.

namespace EqIcon {

constexpr int kItemIconOffset = 500;
constexpr int kCellSize = 40;
constexpr int kSheetSize = 256;
constexpr int kCellsPerSide = kSheetSize / kCellSize; // 6
constexpr int kCellsPerSheet = kCellsPerSide * kCellsPerSide; // 36

void SetUiFilesPath(const char* path);
std::string GetUiFilesPath();

// kind: "item" (Item.Icon()), "itemcell" (raw A_DragItem cell), "spell" (SpellIcon cell)
bool Sample(const char* kind, int id, std::vector<uint8_t>& rgbaOut, int& w, int& h);

// Writes PNG; returns absolute path written, or empty on failure.
// If outPath is null/empty, uses {MQRoot}/lua/rmlui/icons/cache/{kind}_{id}.png
std::string ExportPng(const char* kind, int id, const char* outPath);

// Preferred <img src>. preferFile=true forces PNG export path.
// Otherwise returns eq://… when sampling works, else exported PNG path.
std::string IconSrc(const char* kind, int id, bool preferFile);

bool ParseEqUrl(const std::string& source, std::string& kindOut, int& idOut);

} // namespace EqIcon
