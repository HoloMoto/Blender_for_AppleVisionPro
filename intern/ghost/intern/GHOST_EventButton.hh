/* SPDX-FileCopyrightText: 2001-2002 NaN Holding BV. All rights reserved.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup GHOST
 * Declaration of GHOST_EventButton class.
 */

#pragma once

#include "GHOST_Event.hh"
#include "GHOST_Window.hh"

/**
 * Mouse button event.
 */
class GHOST_EventButton : public GHOST_Event {
 public:
  /**
   * Constructor.
   * \param time: The time this event was generated.
   * \param type: The type of this event.
   * \param window: The window of this event.
   * \param button: The state of the buttons were at the time of the event.
   * \param tablet: The tablet data associated with this event.
   * \param is_touch_drag: The press starts a finger drag on a touch screen.
   */
  GHOST_EventButton(uint64_t time,
                    GHOST_TEventType type,
                    GHOST_IWindow *window,
                    GHOST_TButton button,
                    const GHOST_TabletData &tablet,
                    const bool is_touch_drag = false)
      : GHOST_Event(time, type, window),
        button_event_data_({button, tablet, uint8_t(is_touch_drag ? 1 : 0)})
  {
    data_ = &button_event_data_;
  }

 protected:
  /** The button event data. */
  GHOST_TEventButtonData button_event_data_;
};
