// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license.
#include "mac_video_processor.h"

namespace media {
void MacVideoCadence::Reset() {
  previous_ = origin_ = kCMTimeInvalid;
  tick_ = 1;
  discontinuity_ = true;
}
std::vector<CMTime> MacVideoCadence::Advance(CMTime timestamp, int fps) {
  discontinuity_ =
      !CMTIME_IS_NUMERIC(timestamp) || !CMTIME_IS_NUMERIC(previous_) ||
      CMTimeCompare(timestamp, previous_) <= 0 ||
      CMTimeCompare(CMTimeSubtract(timestamp, previous_), CMTimeMake(1, 4)) > 0;
  if (discontinuity_) {
    origin_ = previous_ = timestamp;
    tick_ = 1;
    return {timestamp};
  }
  std::vector<CMTime> result;
  if (fps == 60 || fps == 120) {
    for (;;) {
      CMTime next = CMTimeAdd(origin_, CMTimeMake(tick_, fps));
      if (CMTimeCompare(next, timestamp) > 0) {
        break;
      }
      result.push_back(next);
      ++tick_;
    }
  } else {
    result.push_back(CMTimeAdd(
        previous_,
        CMTimeMultiplyByRatio(CMTimeSubtract(timestamp, previous_), 1, 2)));
    result.push_back(timestamp);
  }
  previous_ = timestamp;
  return result;
}
}  // namespace media
