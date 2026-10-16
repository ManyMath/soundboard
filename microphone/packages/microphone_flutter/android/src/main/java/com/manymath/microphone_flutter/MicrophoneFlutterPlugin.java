package com.manymath.microphone_flutter;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.pm.PackageManager;
import android.media.AudioDeviceInfo;
import android.media.AudioManager;
import android.os.Build;

import androidx.annotation.NonNull;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

/**
 * What the native capture library cannot do by itself on Android: check and
 * request the RECORD_AUDIO runtime permission (asking needs the app's
 * Activity) and list input devices (AAudio has no enumeration; its device ids
 * are AudioDeviceInfo ids). Capture itself goes over FFI, not this channel.
 */
public final class MicrophoneFlutterPlugin
    implements FlutterPlugin,
        ActivityAware,
        MethodChannel.MethodCallHandler,
        PluginRegistry.RequestPermissionsResultListener {
  private static final String CHANNEL = "microphone_flutter";
  // Any app-unique value; it only routes the result back to this plugin.
  private static final int REQUEST_CODE = 0x6d63;

  private MethodChannel channel;
  private Context context;
  private ActivityPluginBinding activity;
  // Calls waiting on the one outstanding system prompt.
  private final List<MethodChannel.Result> pending = new ArrayList<>();

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    context = binding.getApplicationContext();
    channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
    channel.setMethodCallHandler(this);
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    channel.setMethodCallHandler(null);
    channel = null;
    context = null;
  }

  @Override
  public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
    activity = binding;
    binding.addRequestPermissionsResultListener(this);
  }

  @Override
  public void onDetachedFromActivityForConfigChanges() {
    detachActivity();
  }

  @Override
  public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
    onAttachedToActivity(binding);
  }

  @Override
  public void onDetachedFromActivity() {
    detachActivity();
    // No Activity will deliver the answer now; report the state as it stands.
    answerPending(granted());
  }

  private void detachActivity() {
    if (activity != null) {
      activity.removeRequestPermissionsResultListener(this);
      activity = null;
    }
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
    switch (call.method) {
      case "hasPermission":
        result.success(granted());
        break;
      case "requestPermission":
        if (granted()) {
          result.success(true);
        } else if (!pending.isEmpty()) {
          // A prompt is already up (perhaps across an Activity recreation,
          // while no Activity is attached); share its answer.
          pending.add(result);
        } else if (activity == null) {
          // Without an Activity (e.g. a background engine) there is nothing
          // to show the prompt on.
          result.success(false);
        } else {
          pending.add(result);
          Activity host = activity.getActivity();
          host.requestPermissions(new String[] {Manifest.permission.RECORD_AUDIO}, REQUEST_CODE);
        }
        break;
      case "devices":
        result.success(inputDevices());
        break;
      default:
        result.notImplemented();
    }
  }

  private List<Map<String, Object>> inputDevices() {
    List<Map<String, Object>> out = new ArrayList<>();
    if (context == null) return out;
    AudioManager audio = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
    for (AudioDeviceInfo device : audio.getDevices(AudioManager.GET_DEVICES_INPUTS)) {
      if (!recordable(device.getType())) continue;
      Map<String, Object> entry = new HashMap<>();
      entry.put("id", device.getId());
      entry.put("name", describe(device));
      out.add(entry);
    }
    return out;
  }

  /** Inputs an ordinary app can open (not telephony, tuners, or loopbacks). */
  private static boolean recordable(int type) {
    switch (type) {
      case AudioDeviceInfo.TYPE_TELEPHONY:
      case AudioDeviceInfo.TYPE_FM_TUNER:
      case AudioDeviceInfo.TYPE_TV_TUNER:
      case AudioDeviceInfo.TYPE_REMOTE_SUBMIX:
        return false;
      default:
        return true;
    }
  }

  private static String describe(AudioDeviceInfo device) {
    String kind;
    switch (device.getType()) {
      case AudioDeviceInfo.TYPE_BUILTIN_MIC:
        // A phone's several built-in microphones differ only by address
        // ("bottom", "back", ...).
        String address = Build.VERSION.SDK_INT >= 28 ? device.getAddress() : "";
        return address == null || address.isEmpty()
            ? "Built-in microphone"
            : "Built-in microphone (" + address + ")";
      case AudioDeviceInfo.TYPE_WIRED_HEADSET:
        kind = "Wired headset";
        break;
      case AudioDeviceInfo.TYPE_BLUETOOTH_SCO:
      case AudioDeviceInfo.TYPE_BLE_HEADSET:
        kind = "Bluetooth headset";
        break;
      case AudioDeviceInfo.TYPE_USB_DEVICE:
      case AudioDeviceInfo.TYPE_USB_HEADSET:
      case AudioDeviceInfo.TYPE_USB_ACCESSORY:
        kind = "USB";
        break;
      default:
        kind = "Input";
    }
    CharSequence product = device.getProductName();
    return product == null || product.length() == 0 ? kind : product + " (" + kind + ")";
  }

  @Override
  public boolean onRequestPermissionsResult(
      int requestCode, @NonNull String[] permissions, @NonNull int[] grantResults) {
    if (requestCode != REQUEST_CODE) return false;
    // grantResults is empty when the request was interrupted; the permission
    // state itself is the reliable answer either way.
    answerPending(granted());
    return true;
  }

  private void answerPending(boolean grantedNow) {
    for (MethodChannel.Result result : pending) {
      result.success(grantedNow);
    }
    pending.clear();
  }

  private boolean granted() {
    return context != null
        && context.checkSelfPermission(Manifest.permission.RECORD_AUDIO)
            == PackageManager.PERMISSION_GRANTED;
  }
}
