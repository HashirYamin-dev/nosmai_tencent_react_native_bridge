import type {HostComponent, ViewProps} from 'react-native';
import {codegenNativeComponent} from 'react-native';

/** Fabric renderer host view. All Tencent frame delivery stays in native code. */
export interface NativeProps extends ViewProps {
  debugTag?: string;
}

export default codegenNativeComponent<NativeProps>(
  'NTBRemoteVideoView',
) as HostComponent<NativeProps>;
