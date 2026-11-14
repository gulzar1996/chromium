// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license.
#ifndef MEDIA_GPU_MAC_MAC_VIDEO_PRESENTATION_QUEUE_H_
#define MEDIA_GPU_MAC_MAC_VIDEO_PRESENTATION_QUEUE_H_
#include <deque>
#include <map>
#include <optional>
#include <utility>
namespace media {
// Decode callbacks may arrive before or after the codec schedules a picture.
// Only the codec's presentation order may release pixels to temporal effects.
// Value may contain a dropped/null image, which still consumes its picture.
template <class Key, class Value>
class MacVideoPresentationQueue {
 public:
  void Schedule(Key key) { scheduled_.push_back(std::move(key)); }
  void Fulfill(Key key, Value value) {
    fulfilled_.emplace(std::move(key), std::move(value));
  }
  std::optional<Value> Pop() {
    if (scheduled_.empty()) {
      return std::nullopt;
    }
    auto it = fulfilled_.find(scheduled_.front());
    if (it == fulfilled_.end()) {
      return std::nullopt;
    }
    Value value = std::move(it->second);
    fulfilled_.erase(it);
    scheduled_.pop_front();
    return value;
  }
  bool empty() const { return scheduled_.empty(); }
  void Clear() {
    scheduled_.clear();
    fulfilled_.clear();
  }

 private:
  std::deque<Key> scheduled_;
  std::map<Key, Value> fulfilled_;
};
}  // namespace media
#endif
