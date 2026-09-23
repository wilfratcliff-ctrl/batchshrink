import { requireNativeView, requireOptionalNativeModule } from 'expo';
import { Platform, StyleSheet, Text, View, type ViewProps } from 'react-native';

const NativePipelineView =
  Platform.OS === 'ios' && requireOptionalNativeModule('VideoShrinkNative')
    ? requireNativeView<ViewProps>('VideoShrinkNative')
    : null;

export default function App() {
  if (!NativePipelineView) {
    return (
      <View style={styles.notice}>
        <Text style={styles.title}>BatchShrink needs its iPhone development build</Text>
        <Text style={styles.body}>
          The Photos and HEVC pipeline uses custom Swift code. Install the BatchShrink
          development build, then connect it to this development server. Expo Go,
          Android and web cannot run this prototype.
        </Text>
      </View>
    );
  }

  return <NativePipelineView style={styles.pipeline} />;
}

const styles = StyleSheet.create({
  pipeline: { flex: 1 },
  notice: { flex: 1, padding: 32, justifyContent: 'center', gap: 16, backgroundColor: '#060911' },
  title: { fontSize: 24, fontWeight: '600', color: '#A8F5D1' },
  body: { fontSize: 17, lineHeight: 25, color: '#A3ADBF' },
});
