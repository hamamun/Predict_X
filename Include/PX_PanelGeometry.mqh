#ifndef __PX_PANEL_GEOMETRY_MQH__
#define __PX_PANEL_GEOMETRY_MQH__

// Shared two-panel geometry. The right order-manager panel is derived from
// the left panel so it always stays adjacent if the left-panel size changes.
// Left panel width/height are DYNAMIC at runtime (g_pxMainPanelW/H) so Aladin
// step text and wrapped blocks can grow the panel instead of clipping.
#define PX_PNL_X            5
#define PX_PNL_Y            18
#define PX_PNL_W_MIN        455
#define PX_PNL_H_MIN        462
#define PX_PNL_W_MAX        620
#define PX_TEXT_X           14
#define PX_TEXT_PAD_R       16
#define PX_PNL_GAP          10
#define PX_RIGHT_PNL_W      365
#define PX_MAIN_PANEL_BG_NAME "PX_PANEL_BG"

// Runtime size of the left main panel (updated by PX_RenderPanel each draw).
int g_pxMainPanelW = PX_PNL_W_MIN;
int g_pxMainPanelH = PX_PNL_H_MIN;

// Back-compat aliases used by older call sites.
#define PX_PNL_W            g_pxMainPanelW
#define PX_PNL_H            g_pxMainPanelH
#define PX_RIGHT_PNL_X      (PX_PNL_X+g_pxMainPanelW+PX_PNL_GAP)
#define PX_RIGHT_PNL_Y      PX_PNL_Y
#define PX_RIGHT_PNL_H      g_pxMainPanelH

int PX_RightPanelX()
{
   return PX_PNL_X + g_pxMainPanelW + PX_PNL_GAP;
}

#endif
