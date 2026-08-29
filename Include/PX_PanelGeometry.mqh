#ifndef __PX_PANEL_GEOMETRY_MQH__
#define __PX_PANEL_GEOMETRY_MQH__

// Shared two-panel geometry. The right order-manager panel is derived from
// the left panel so it always stays adjacent if the left-panel size changes.
#define PX_PNL_X            5
#define PX_PNL_Y            18
#define PX_PNL_W            455
#define PX_PNL_H            462
#define PX_TEXT_X           14
#define PX_TEXT_PAD_R       16
#define PX_PNL_GAP          10
#define PX_RIGHT_PNL_X      (PX_PNL_X+PX_PNL_W+PX_PNL_GAP)
#define PX_RIGHT_PNL_Y      PX_PNL_Y
#define PX_RIGHT_PNL_W      PX_PNL_W
#define PX_RIGHT_PNL_H      PX_PNL_H
#define PX_MAIN_PANEL_BG_NAME "PX_PANEL_BG"

#endif
