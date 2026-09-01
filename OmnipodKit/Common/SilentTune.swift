//
//  SilentTune.swift
//  OmnipodKit
//
//  Created by Joe Moran on 7/21/26.
//  Copyright © 2026 Joe Moran. All rights reserved.
//

import AVFoundation

/// Plays a silent tune to keep the app active
class SilentTune {

    // MARK: - Vars

    var player = AVAudioPlayer()

    // MARK: - Methods

    func startPlayer() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(interruptedAudio),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        playAudio()
    }

    func stopPlayer() {
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        player.stop()
    }

    // MARK: private audio functions

    @objc private func interruptedAudio(_ notification: Notification) {
        if notification.name == AVAudioSession.interruptionNotification, notification.userInfo != nil {
            let info = notification.userInfo!
            var intValue = 0
            (info[AVAudioSessionInterruptionTypeKey]! as AnyObject).getValue(&intValue)
            if intValue == 1 {
                playAudio()
            }
        }
    }

    private func playAudio() {
        do {
            let bundle = Bundle(for: OmniHUDProvider.self).path(forResource: "silent", ofType: "wav")
            let alertSound = URL(fileURLWithPath: bundle!)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: .mixWithOthers)
            try AVAudioSession.sharedInstance().setActive(true)
            try player = AVAudioPlayer(contentsOf: alertSound)
            // Play audio forever by setting num of loops to -1
            player.numberOfLoops = -1
            player.volume = 0.01
            player.prepareToPlay()
            player.play()
        } catch {
            print(error)
        }
    }
}
