/**
 * Opt-in high-level React Native integration for Nosmai Effects + Tencent TRTC.
 * Frames remain on existing native Android GPU / iOS CVPixelBuffer paths.
 * This file does not replace or edit native code.
 */
import React, {
  forwardRef,
  useCallback,
  useEffect,
  useImperativeHandle,
  useRef,
  useState,
} from 'react';
import {
  PermissionsAndroid,
  Platform,
  StyleSheet,
  View,
  type StyleProp,
  type ViewStyle,
} from 'react-native';
import {
  NosmaiCameraSdk,
  NosmaiCameraView,
} from '@nosmai/react-native-effects-sdk';
import {
  NosmaiTencentBridge,
  NosmaiTencentEvents,
  NosmaiLocalCameraView,
  TrtcRemoteVideoView,
  TrtcViewer,
  type BridgeEvent,
  type HostOptions,
  type ViewerOptions,
} from './core';

export type EasyStatus =
  | 'mounting'
  | 'initializing'
  | 'ready'
  | 'starting'
  | 'start-requested'
  | 'joined'
  | 'stopping'
  | 'stopped'
  | 'joining'
  | 'join-requested'
  | 'first-video-frame'
  | 'left'
  | 'error';

type Callbacks = {
  onStatus?: (status: EasyStatus, detail?: string) => void;
  onEvent?: (event: BridgeEvent) => void;
  onError?: (error: Error) => void;
};

export type NosmaiTencentHostProps = Callbacks & {
  licenseKey: string;
  session: HostOptions;
  style?: StyleProp<ViewStyle>;
  /** Start streaming automatically after camera processing initializes. Default true. */
  autoStart?: boolean;
  /** Optional beauty setting. Failure does not prevent video publication. */
  smoothing?: number;
};

export type NosmaiTencentHostRef = {
  start: () => Promise<void>;
  stop: () => Promise<void>;
  switchCamera: () => Promise<void>;
  setSmoothing: (amount: number) => Promise<void>;
  /** Mute/unmute the published microphone while streaming. Resets on stop. */
  muteAudio: (mute: boolean) => Promise<void>;
  /** Pause/resume the published video while streaming. Resets on stop. */
  muteVideo: (mute: boolean) => Promise<void>;
};

export type NosmaiTencentViewerProps = Callbacks & {
  session: ViewerOptions;
  style?: StyleProp<ViewStyle>;
  /** Join automatically after the remote native video view mounts. Default true. */
  autoJoin?: boolean;
};

export type NosmaiTencentViewerRef = {
  join: () => Promise<void>;
  leave: () => Promise<void>;
};

const errorOf = (value: unknown): Error =>
  value instanceof Error ? value : new Error(String(value));

const sleep = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms));

/**
 * iOS native start() refuses to go live until NosmaiCore has delivered a
 * processed frame (VIDEO_NOT_READY). initializeNosmaiCamera() resolves as soon
 * as capture starts, which is before that first frame, so wait for it here.
 * `seen` is set by the Host event subscription on `firstSourceFrame`; the
 * native counter is polled as a fallback in case that event was missed.
 */
async function waitForIosSourceFrame(
  seen: {current: boolean},
  isCancelled: () => boolean,
  timeoutMs = 8000,
) {
  const deadline = Date.now() + timeoutMs;
  let nextPoll = 0;
  while (!seen.current) {
    if (isCancelled()) return;
    if (Date.now() >= nextPoll) {
      nextPoll = Date.now() + 500;
      try {
        const fps = await NosmaiTencentBridge.getHostFps();
        if ((fps.sourceFramesTotal ?? 0) > 0) { seen.current = true; return; }
      } catch (_) { /* keep waiting for the event */ }
    }
    if (Date.now() >= deadline) {
      throw new Error('No processed Nosmai frames within 8s; check camera permission and Nosmai license');
    }
    await sleep(100);
  }
}

async function hostPermissions(publishAudio: boolean) {
  if (Platform.OS !== 'android') return;
  const permissions = publishAudio
    ? [PermissionsAndroid.PERMISSIONS.CAMERA, PermissionsAndroid.PERMISSIONS.RECORD_AUDIO]
    : [PermissionsAndroid.PERMISSIONS.CAMERA];
  const result = await PermissionsAndroid.requestMultiple(permissions);
  for (const permission of permissions) {
    if (result[permission] !== PermissionsAndroid.RESULTS.GRANTED) {
      throw new Error('Required camera/microphone permission was denied');
    }
  }
}

/**
 * Single Host component for BOTH platforms. Mount on a screen and unmount
 * when leaving it. Use a different native process/device for the Viewer.
 * The `onStatus('start-requested')` callback is NOT proof of a connected stream.
 */
export const NosmaiTencentHost = forwardRef<NosmaiTencentHostRef, NosmaiTencentHostProps>(
  function NosmaiTencentHost(
    {licenseKey, session, style, autoStart = true, smoothing, onStatus, onEvent, onError},
    ref,
  ) {
    const [mounted, setMounted] = useState(false);
    const callbacks = useRef<Callbacks>({onStatus, onEvent, onError});
    callbacks.current = {onStatus, onEvent, onError};
    const cameraReady = useRef(false);
    const cancelled = useRef(false);
    const initPromise = useRef<Promise<void> | null>(null);
    const startPromise = useRef<Promise<void> | null>(null);
    const started = useRef(false);
    const sourceFrameSeen = useRef(false);

    const status = useCallback((value: EasyStatus, detail?: string) => {
      if (!cancelled.current) callbacks.current.onStatus?.(value, detail);
    }, []);
    const report = useCallback((error: unknown) => {
      if (cancelled.current) return;
      const safeError = errorOf(error);
      status('error', safeError.message);
      callbacks.current.onError?.(safeError);
    }, [status]);

    const start = useCallback(async () => {
      if (!cameraReady.current) throw new Error('Nosmai camera is not ready yet');
      if (started.current) return;
      if (startPromise.current) return startPromise.current;
      const task = (async () => {
        status('starting');
        if (Platform.OS === 'ios') {
          await waitForIosSourceFrame(sourceFrameSeen, () => cancelled.current || !cameraReady.current);
          if (cancelled.current || !cameraReady.current) return;
        }
        const accepted = await NosmaiTencentBridge.startStreaming({
          sdkAppId: session.sdkAppId,
          roomId: session.roomId,
          userId: session.userId,
          userSig: session.userSig,
          publishAudio: session.publishAudio ?? true,
          ...(session.video ? {video: session.video} : {}),
        });
        if (accepted === false) throw new Error('TRTC Host start request rejected');
        started.current = true;
        status('start-requested', 'Waiting for native joined/uplink events');
      })();
      startPromise.current = task;
      try { await task; } finally { startPromise.current = null; }
    }, [session.sdkAppId, session.roomId, session.userId, session.userSig, session.publishAudio, session.video, status]);

    const stop = useCallback(async () => {
      if (startPromise.current) {
        try { await startPromise.current; } catch (_) { /* still stop */ }
      }
      if (!started.current) return;
      status('stopping');
      await NosmaiTencentBridge.stopStreaming();
      started.current = false;
      status('stopped');
    }, [status]);

    const switchCamera = useCallback(async () => {
      if (!cameraReady.current) throw new Error('Camera not ready');
      if (Platform.OS === 'ios') await NosmaiTencentBridge.switchNosmaiCamera();
      else await NosmaiCameraSdk.switchCamera();
    }, []);

    const setSmoothing = useCallback(async (amount: number) => {
      if (!cameraReady.current) throw new Error('Camera not ready');
      if (Platform.OS === 'ios') await NosmaiTencentBridge.setNosmaiSmoothing(amount);
      else await NosmaiCameraSdk.setSkinSmoothing(amount);
    }, []);

    const muteAudio = useCallback(async (mute: boolean) => {
      if (!started.current) throw new Error('Host is not streaming');
      await NosmaiTencentBridge.muteLocalAudio(mute);
    }, []);

    const muteVideo = useCallback(async (mute: boolean) => {
      if (!started.current) throw new Error('Host is not streaming');
      await NosmaiTencentBridge.muteLocalVideo(mute);
    }, []);

    useImperativeHandle(ref, () => ({start, stop, switchCamera, setSmoothing, muteAudio, muteVideo}),
      [start, stop, switchCamera, setSmoothing, muteAudio, muteVideo]);

    // Credentials/licenses are treated as immutable for a mounted session.
    // To change identity or room, unmount/remount the component with a new key.
    useEffect(() => {
      cancelled.current = false;
      const subscription = NosmaiTencentEvents.subscribe(event => {
        if (cancelled.current) return;
        callbacks.current.onEvent?.(event);
        if (event.type === 'firstSourceFrame') sourceFrameSeen.current = true;
        if (event.type === 'joined') status('joined');
        if (event.type === 'left' || event.type === 'joinFailed') started.current = false;
        if (event.type === 'error' || event.type === 'joinFailed') {
          status('error', String(event.message ?? event.type));
        }
      });
      return () => {
        cancelled.current = true;
        subscription.remove();
      };
    }, [status]);

    useEffect(() => {
      if (!mounted) return;
      let disposed = false;
      cancelled.current = false;
      cameraReady.current = false;
      started.current = false;
      sourceFrameSeen.current = false;
      const initialize = async () => {
        status('initializing');
        if (!licenseKey) throw new Error('Nosmai licenseKey is required');
        await hostPermissions(session.publishAudio ?? true);
        if (disposed) return;
        await NosmaiTencentBridge.initialize();
        if (disposed) return;
        if (Platform.OS === 'ios') {
          const accepted = await NosmaiTencentBridge.initializeNosmaiCamera(licenseKey);
          if (accepted === false) throw new Error('iOS Nosmai initialization rejected');
        } else {
          const accepted = await NosmaiCameraSdk.initialize(licenseKey);
          if (accepted === false) throw new Error('Android Nosmai initialization rejected');
          if (disposed) return;
          await NosmaiCameraSdk.configureCamera({position: 'front'});
          if (disposed) return;
          // A short bounded retry handles occasional native view/GL attach race.
          try {
            const result: unknown = await NosmaiCameraSdk.startProcessing();
            if (result === false) throw new Error('Nosmai startProcessing returned false');
          } catch (error) {
            if (!/pipeline is not ready/i.test(errorOf(error).message)) throw error;
            await new Promise<void>(resolve => setTimeout(resolve, 650));
            if (disposed) return;
            const retry: unknown = await NosmaiCameraSdk.startProcessing();
            if (retry === false) throw new Error('Nosmai startProcessing retry returned false');
          }
        }
        if (disposed) return;
        cameraReady.current = true;
        status('ready');
        if (smoothing !== undefined) {
          try { await setSmoothing(smoothing); }
          catch (error) { status('ready', `Optional beauty unavailable: ${errorOf(error).message}`); }
        }
        if (autoStart && !disposed) await start();
      };
      const task = initialize().catch(error => {
        if (!disposed) report(error);
      });
      initPromise.current = task;
      return () => {
        disposed = true;
        cameraReady.current = false;
        // Finish any in-flight native start before releasing the underlying engine.
        void (async () => {
          try { await task; } catch (_) {}
          try { await stop(); } catch (_) {}
          try {
            if (Platform.OS === 'ios') await NosmaiTencentBridge.stopNosmaiCamera();
            else {
              await NosmaiCameraSdk.stopProcessing();
              await NosmaiCameraSdk.cleanup();
            }
          } catch (_) {}
          try { await NosmaiTencentBridge.dispose(); } catch (_) {}
        })();
      };
      // Session/identity updates require remount, not a live native reconfiguration.
      // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [mounted]);

    return (
      <View collapsable={false} onLayout={() => setMounted(true)} style={style}>
        {Platform.OS === 'ios' ? (
          <NosmaiLocalCameraView style={StyleSheet.absoluteFillObject} />
        ) : (
          <NosmaiCameraView
            style={StyleSheet.absoluteFillObject}
            cameraPosition="front"
            mirror
            onError={error => report((error as any)?.nativeEvent?.message ?? error)}
          />
        )}
      </View>
    );
  },
);

/** Viewer never initializes Nosmai. Mount its native video surface BEFORE join. */
export const NosmaiTencentViewer = forwardRef<NosmaiTencentViewerRef, NosmaiTencentViewerProps>(
  function NosmaiTencentViewer(
    {session, style, autoJoin = true, onStatus, onEvent, onError},
    ref,
  ) {
    const [mounted, setMounted] = useState(false);
    const callbacks = useRef<Callbacks>({onStatus, onEvent, onError});
    callbacks.current = {onStatus, onEvent, onError};
    const cancelled = useRef(false);
    const joinPromise = useRef<Promise<void> | null>(null);
    const joined = useRef(false);
    const status = useCallback((value: EasyStatus, detail?: string) => {
      if (!cancelled.current) callbacks.current.onStatus?.(value, detail);
    }, []);

    const join = useCallback(async () => {
      if (!mounted) throw new Error('Remote video view not mounted yet');
      if (joined.current) return;
      if (joinPromise.current) return joinPromise.current;
      const task = (async () => {
        status('joining');
        // Give React Native one render frame to attach the native video surface.
        await new Promise<void>(resolve => requestAnimationFrame(() => resolve()));
        if (cancelled.current) return;
        const accepted = await TrtcViewer.join({
          sdkAppId: session.sdkAppId,
          roomId: session.roomId,
          userId: session.userId,
          userSig: session.userSig,
          hostUserId: session.hostUserId,
        });
        if (accepted === false) throw new Error('TRTC Viewer join request rejected');
        joined.current = true;
        status('join-requested', 'Waiting for firstVideoFrame');
      })();
      joinPromise.current = task;
      try { await task; } finally { joinPromise.current = null; }
    }, [mounted, session.sdkAppId, session.roomId, session.userId, session.userSig, session.hostUserId, status]);

    const leave = useCallback(async () => {
      if (joinPromise.current) {
        try { await joinPromise.current; } catch (_) {}
      }
      if (!joined.current) return;
      await TrtcViewer.leave();
      joined.current = false;
      status('left');
    }, [status]);

    useImperativeHandle(ref, () => ({join, leave}), [join, leave]);

    useEffect(() => {
      cancelled.current = false;
      const subscription = TrtcViewer.subscribe(event => {
        if (cancelled.current) return;
        callbacks.current.onEvent?.(event);
        if (event.type === 'joined') status('joined');
        if (event.type === 'firstVideoFrame') status('first-video-frame');
        if (event.type === 'left') { joined.current = false; status('left'); }
        if (event.type === 'error') status('error', String(event.message ?? event.type));
      });
      return () => { cancelled.current = true; subscription.remove(); };
    }, [status]);

    useEffect(() => {
      if (!mounted || !autoJoin) return;
      void join().catch(error => {
        if (cancelled.current) return;
        const safeError = errorOf(error);
        status('error', safeError.message);
        callbacks.current.onError?.(safeError);
      });
      // If session changes, consumers should remount with a new key.
      // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [mounted]);

    useEffect(() => () => {
      cancelled.current = true;
      void leave();
    }, [leave]);

    return (
      <View collapsable={false} onLayout={() => setMounted(true)} style={style}>
        <TrtcRemoteVideoView
          collapsable={false}
          style={StyleSheet.absoluteFillObject}
        />
      </View>
    );
  },
);
