#pragma once
#include "Limelight.h"

// Swift cannot import the anonymous nested primary/white-point structs. Export
// the standard big-endian HEVC SEI payloads without exposing their C layout.
static inline void MoonlightCopyHDRMetadata(const SS_HDR_METADATA* hdr, unsigned char mastering[24], unsigned char light[4]) {
    unsigned int values[10] = {
        hdr->displayPrimaries[1].x, hdr->displayPrimaries[1].y,
        hdr->displayPrimaries[2].x, hdr->displayPrimaries[2].y,
        hdr->displayPrimaries[0].x, hdr->displayPrimaries[0].y,
        hdr->whitePoint.x, hdr->whitePoint.y,
        (unsigned int)hdr->maxDisplayLuminance * 10000U, hdr->minDisplayLuminance
    };
    for (int i = 0; i < 8; i++) { mastering[i*2] = values[i] >> 8; mastering[i*2+1] = values[i]; }
    for (int i = 0; i < 2; i++) for (int j = 0; j < 4; j++) mastering[16+i*4+j] = values[8+i] >> (24-j*8);
    light[0] = hdr->maxContentLightLevel >> 8; light[1] = hdr->maxContentLightLevel;
    light[2] = hdr->maxFrameAverageLightLevel >> 8; light[3] = hdr->maxFrameAverageLightLevel;
}
