// Included in Bridge. Recording observes the page independently of input/control
// leases. Its owner is still the exact native Agent run that started it.
 private:
  struct Recording {
    std::string tab, owner;
    NSString* identifier = NSUUID.UUID.UUIDString;
    NSString* path;
    NSString* state = @"starting";
    NSString* reason = nil;
    NSString* error = nil;
    int seconds, fps, frames = 0;
    int64_t bytes = 0;
    bool pending = true, finishing = false;
    Clock::time_point created = Clock::now(), started = created, next = created, lastFrame = created, stopped;
    std::shared_ptr<BrowserRecordingWriter> writer;
    bool Active() const { return [@[@"starting", @"recording", @"stopping"] containsObject:state]; }
    NSDictionary* Status() const {
      auto end = reason ? stopped : Clock::now();
      NSMutableDictionary* result = [@{@"id": identifier, @"tab": String(tab), @"state": state,
        @"path": path, @"format": @"mp4", @"fps": @(fps), @"frames": @(frames), @"bytes": @(bytes),
        @"maximumSeconds": @(seconds), @"maximumBytes": @(kBrowserRecordingMaximumBytes),
        @"elapsedSeconds": @(std::max(0.0, std::chrono::duration<double>(end - started).count()))} mutableCopy];
      if (reason) result[@"reason"] = reason;
      if (error) result[@"error"] = error;
      return result;
    }
  };
  std::map<std::string, std::shared_ptr<Recording>> recordings_;

  bool RecordingActive(const std::string& tab) {
    auto found = recordings_.find(tab);
    return found != recordings_.end() && found->second->Active();
  }

  void FinishRecording(std::shared_ptr<Recording> recording) {
    if (recording->pending || recording->finishing || ![recording->state isEqual:@"stopping"]) return;
    recording->finishing = true;
    const double seconds = std::chrono::duration<double>(recording->stopped - recording->started).count();
    CefRefPtr<Bridge> self = this;
    CefPostTask(TID_FILE_USER_VISIBLE, new Action([self, recording, seconds] {
      auto writer = recording->writer;
      writer->Finish(seconds, [self, recording, writer](NSDictionary* result) {
        CefPostTask(TID_UI, new Action([self, recording, result] {
          recording->state = result[@"state"];
          recording->bytes = [result[@"bytes"] longLongValue];
          recording->frames = [result[@"frames"] intValue];
          if (result[@"error"] && !recording->error) recording->error = result[@"error"];
          recording->writer.reset();
          --browserRecordingJobs;
        }));
      });
    }));
  }

  void StopRecording(std::shared_ptr<Recording> recording, NSString* reason) {
    if (!recording->Active()) return;
    if (![recording->state isEqual:@"stopping"]) {
      recording->state = @"stopping";
      recording->reason = reason;
      recording->stopped = Clock::now();
    }
    FinishRecording(recording);
  }

  void RecordingTick() {
    for (auto& [id, recording] : recordings_) {
      if (!recording->Active() || [recording->state isEqual:@"stopping"]) continue;
      if (!tabs_.contains(id)) { StopRecording(recording, @"tab-closed"); continue; }
      if (!ownership_.Owns(recording->owner, id)) { StopRecording(recording, @"owner-ended"); continue; }
      auto now = Clock::now();
      if (now - recording->started >= std::chrono::seconds(recording->seconds)) {
        StopRecording(recording, @"duration-limit"); continue;
      }
      if (now - recording->lastFrame >= std::chrono::seconds(10)) {
        recording->error = @"No recording frame was available for 10 seconds.";
        StopRecording(recording, @"capture-failed"); continue;
      }
      if (recording->pending || now < recording->next) continue;
      recording->pending = true;
      recording->next = now + std::chrono::milliseconds(1000 / recording->fps);
      CefRefPtr<Bridge> self = this;
      RemoteCall(id, "Page.captureScreenshot", @{@"format": @"jpeg", @"quality": @80,
        @"fromSurface": @YES, @"captureBeyondViewport": @NO},
        [self, recording](NSDictionary* result, NSString* error) {
          if (!self->ownership_.Owns(recording->owner, recording->tab)) self->StopRecording(recording, @"owner-ended");
          if (error || [recording->state isEqual:@"stopping"]) {
            // Navigation invalidates an old frame, not the recording. The next
            // sample observes the new document without replaying any input.
            recording->pending = false;
            self->FinishRecording(recording);
            return;
          }
          NSString* encoded = result[@"data"];
          double elapsed = recording->frames ? std::chrono::duration<double>(Clock::now() - recording->started).count() : 0;
          CefPostTask(TID_FILE_USER_VISIBLE, new Action([self, recording, encoded, elapsed] {
            NSString* failure = recording->writer->Append(encoded, elapsed);
            auto bytes = recording->writer->Bytes();
            int frames = recording->writer->Frames();
            bool limit = recording->writer->AtSizeLimit();
            CefPostTask(TID_UI, new Action([self, recording, failure, bytes, frames, limit] {
              if (frames > recording->frames) {
                if (!recording->frames) recording->started = Clock::now();
                recording->lastFrame = Clock::now();
                if ([recording->state isEqual:@"starting"]) recording->state = @"recording";
              }
              recording->bytes = bytes; recording->frames = frames; recording->pending = false;
              if (failure) {
                recording->error = failure;
                self->StopRecording(recording, @"encoder-failed");
              } else if (limit) self->StopRecording(recording, @"size-limit");
              self->FinishRecording(recording);
            }));
          }));
        }, kRemoteScreenshotResponseBytes);
    }
  }

  bool RecordingRequest(int clientID, NSDictionary* request) {
    NSString* command = request[@"command"];
    if (![@[@"record-start", @"record-stop", @"record-status"] containsObject:command]) return false;
    auto& client = clients_.at(clientID);
    NSString* token = request[@"tab"];
    if (![token isKindOfClass:NSString.class]) { Reply(clientID, nil, @"Recording requires an explicit tab."); return true; }
    const std::string tabID = token.UTF8String;
    auto found = recordings_.find(tabID);
    auto tab = tabs_.find(tabID);
    if ([command isEqual:@"record-start"]) {
      if (tab == tabs_.end() || !ownership_.Owns(client.run, tabID) || humanControl_.contains(tabID)) {
        Reply(clientID, nil, @"Recording requires a live page owned by this Agent, with control returned by the Viewer."); return true;
      }
      bool busy = RecordingActive(tabID) || engineCaptureAttaching_.contains(tab->second.browser->GetIdentifier());
      for (auto& [key, deadline] : engineCaptures_) busy |= key.first == tab->second.browser->GetIdentifier();
      int active = 0;
      for (auto& [id, recording] : recordings_) active += recording->Active();
      if (busy || active >= 4) { Reply(clientID, nil, @"Recording already active, or this Host has four active recordings."); return true; }
      NSMutableDictionary* params = [request mutableCopy];
      NSString* output = params[@"output"];
      if (![output isKindOfClass:NSString.class] || !output.isAbsolutePath || output.length > 4096 ||
          [output rangeOfCharacterFromSet:[NSCharacterSet characterSetWithRange:NSMakeRange(0, 1)]].location != NSNotFound || ![output.pathExtension.lowercaseString isEqual:@"mp4"] ||
          !Integer(params, @"seconds", 600, 1, kBrowserRecordingMaximumSeconds) || !Integer(params, @"fps", 10, 1, 30)) {
        Reply(clientID, nil, @"Use a new absolute .mp4 path, 1...600 seconds and 1...30 fps."); return true;
      }
      // Retain bounded completion status, including after a tab closes.
      while (recordings_.size() >= 32) {
        auto oldest = recordings_.end();
        for (auto it = recordings_.begin(); it != recordings_.end(); ++it)
          if (!it->second->Active() && (oldest == recordings_.end() || it->second->created < oldest->second->created)) oldest = it;
        if (oldest == recordings_.end()) break;
        recordings_.erase(oldest);
      }
      auto recording = std::make_shared<Recording>();
      recording->tab = tabID; recording->owner = client.run;
      recording->path = output.stringByStandardizingPath;
      recording->seconds = [params[@"seconds"] intValue]; recording->fps = [params[@"fps"] intValue];
      recording->writer = std::make_shared<BrowserRecordingWriter>(recording->path, recording->fps);
      recordings_[tabID] = recording;
      ++browserRecordingJobs;
      CefRefPtr<Bridge> self = this;
      CefPostTask(TID_FILE_USER_VISIBLE, new Action([self, recording] {
        NSString* error = recording->writer->Prepare();
        CefPostTask(TID_UI, new Action([self, recording, error] {
          recording->pending = false;
          if (error) { recording->error = error; self->StopRecording(recording, @"failed"); }
          self->FinishRecording(recording);
        }));
      }));
      Reply(clientID, recording->Status()); return true;
    }
    if (found == recordings_.end()) {
      if (tab != tabs_.end() && ownership_.Owns(client.run, tabID)) Reply(clientID, @{@"state": @"idle"});
      else Reply(clientID, nil, @"Unknown or unowned recording.");
      return true;
    }
    auto recording = found->second;
    if (recording->owner != client.run || (tab != tabs_.end() && !ownership_.Owns(client.run, tabID))) {
      Reply(clientID, nil, @"Recording belongs to another Agent instance."); return true;
    }
    if (request[@"recording"] && ![request[@"recording"] isEqual:recording->identifier]) {
      Reply(clientID, nil, @"Recording ID changed; no action sent."); return true;
    }
    if ([command isEqual:@"record-stop"]) StopRecording(recording, @"stopped");
    Reply(clientID, recording->Status()); return true;
  }
