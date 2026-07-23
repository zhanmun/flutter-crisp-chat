package com.alaminkarno.flutter_crisp_chat;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

import androidx.annotation.NonNull;

import com.alaminkarno.flutter_crisp_chat.config.CrispConfig;
import com.google.firebase.messaging.FirebaseMessaging;

import java.util.HashMap;
import java.util.List;
import java.util.Locale;

import im.crisp.client.external.ChatActivity;
import im.crisp.client.external.Crisp;
import im.crisp.client.external.data.SessionEvent.Color;
import im.crisp.client.external.notification.CrispNotificationClient;

import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import io.flutter.plugin.common.PluginRegistry;

/**
 * [FlutterCrispChatPlugin] using [FlutterPlugin], [MethodCallHandler] and [ActivityAware]
 * to handling Method Channel Callback from Flutter and Open new Activity.
 */
public class FlutterCrispChatPlugin implements FlutterPlugin, MethodCallHandler, ActivityAware, PluginRegistry.NewIntentListener {

    private static final String CHANNEL_NAME = "flutter_crisp_chat";
    private static final String PREFS_NAME = "flutter_crisp_chat_prefs";
    private static final String LAST_WEBSITE_ID_KEY = "last_website_id";

    private MethodChannel channel;
    private Context context;
    private Activity activity;
    private ActivityPluginBinding activityBinding;

    private static void persistLastWebsiteId(Context context, String websiteId) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(LAST_WEBSITE_ID_KEY, websiteId)
            .apply();
    }

    /**
     * Ensures Crisp.configure() has been called at least once in this process, using the
     * last website ID configured by the Flutter side. CrispChatNotificationService needs
     * this before calling into Crisp's SDK (e.g. sendTokenToCrisp()), since those calls NPE
     * internally if Crisp was never configured - e.g. an FCM token/message arriving at
     * process cold-start, before the app has run configureCrispSession()/openCrispChat().
     * Returns false if there's no known website ID yet (Crisp has never been configured on
     * this device at all), in which case there is nothing to associate the call with.
     */
    /**
     * Re-associates the device's current FCM token with Crisp's backend for the session
     * just configured. There is no token-refresh listener in the host app, so this piggybacks
     * on every configureCrispSession()/openCrispChat() call - i.e. every point where the
     * session identity actually changes (login, logout, guest) - rather than requiring a
     * second FirebaseMessagingService, which would conflict with the host app's own FCM
     * service (Android only delivers onMessageReceived/onNewToken to one registered service).
     */
    private static void forwardCurrentFcmTokenToCrisp(Context context) {
        FirebaseMessaging.getInstance().getToken().addOnCompleteListener(task -> {
            if (task.isSuccessful() && task.getResult() != null) {
                CrispNotificationClient.sendTokenToCrisp(context, task.getResult());
            }
        });
    }

    static boolean ensureConfigured(Context context) {
        String lastWebsiteId = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(LAST_WEBSITE_ID_KEY, null);
        if (lastWebsiteId == null || lastWebsiteId.isEmpty()) {
            return false;
        }
        Crisp.configure(context, lastWebsiteId);
        return true;
    }

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding flutterPluginBinding) {
        context = flutterPluginBinding.getApplicationContext();

        channel = new MethodChannel(flutterPluginBinding.getBinaryMessenger(), CHANNEL_NAME);
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        this.activityBinding = binding;
        this.activity = binding.getActivity();
        binding.addOnNewIntentListener(this);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        if (activityBinding != null) {
            activityBinding.removeOnNewIntentListener(this);
        }
        this.activityBinding = null;
        this.activity = null;
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        this.activityBinding = binding;
        this.activity = binding.getActivity();
        binding.addOnNewIntentListener(this);
    }

    @Override
    public void onDetachedFromActivity() {
        if (activityBinding != null) {
            activityBinding.removeOnNewIntentListener(this);
        }
        this.activityBinding = null;
        this.activity = null;
    }

    @Override
    public boolean onNewIntent(@NonNull Intent intent) {
        if (activity != null) {
            activity.setIntent(intent);
        }
        // Notify Flutter side about a new intent (potential Crisp notification tap)
        if (channel != null) {
            channel.invokeMethod("onCrispNotificationTapped", null);
        }
        return false;
    }

    /// [onMethodCall] if for handling method call from flutter end.
    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
        if (call.method.equals("openCrispChat")) {
            HashMap<String, Object> args = (HashMap<String, Object>) call.arguments;
            if (args != null) {
                CrispConfig config = CrispConfig.fromJson(args);

                if(config.websiteId == null || config.websiteId.equals("")) {
                    result.error("INVALID_ARGUMENTS", "Missing 'websiteId' argument", null);
                    return;
                }

                if (config.tokenId != null) {
                    Crisp.configure(context, config.websiteId, config.tokenId);
                } else {
                    Crisp.configure(context, config.websiteId);
                }
                persistLastWebsiteId(context, config.websiteId);
                forwardCurrentFcmTokenToCrisp(context);

                Crisp.enableNotifications(context, config.enableNotifications);
                setCrispData(context, config);
                openActivity();
                result.success(null);
            } else {
                result.notImplemented();
            }
        } else if (call.method.equals("configureCrispSession")) {
            HashMap<String, Object> args = (HashMap<String, Object>) call.arguments;
            if (args != null) {
                CrispConfig config = CrispConfig.fromJson(args);

                if (config.websiteId == null || config.websiteId.equals("")) {
                    result.error("INVALID_ARGUMENTS", "Missing 'websiteId' argument", null);
                    return;
                }

                if (config.tokenId != null) {
                    Crisp.configure(context, config.websiteId, config.tokenId);
                } else {
                    Crisp.configure(context, config.websiteId);
                }
                persistLastWebsiteId(context, config.websiteId);
                forwardCurrentFcmTokenToCrisp(context);

                Crisp.enableNotifications(context, config.enableNotifications);
                setCrispData(context, config);
                result.success(null);
            } else {
                result.notImplemented();
            }
        } else if (call.method.equals("resetCrispChatSession")) {
            Crisp.resetChatSession(context);
            result.success(null);
        } else if (call.method.equals("setSessionString")) {
            HashMap<String, Object> args = (HashMap<String, Object>) call.arguments;
            if (args != null) {
                String key = (String) args.get("key");
                String value = (String) args.get("value");
                Crisp.setSessionString(key, value);
                result.success(null);
            } else {
                result.notImplemented();
            }
        } else if (call.method.equals("setSessionInt")) {
            HashMap<String, Object> args = (HashMap<String, Object>) call.arguments;
            if (args != null) {
                String key = (String) args.get("key");
                int value = (int) args.get("value");
                Crisp.setSessionInt(key, value);
                result.success(null);
            } else {
                result.notImplemented();
            }
        } else if (call.method.equals("getSessionIdentifier")) {
            String sessionId = Crisp.getSessionIdentifier(context);
            if (sessionId != null) {
                result.success(sessionId);
            } else {
                result.error("NO_SESSION", "No active session found", null);
            }
        } else if (call.method.equals("setSessionSegments")) {
            HashMap<String, Object> args = (HashMap<String, Object>) call.arguments;
            if (args != null) {
                List<String> segments = (List<String>) args.get("segments");
                boolean overwrite = (boolean) args.get("overwrite");
                Crisp.setSessionSegments(segments, overwrite);
                result.success(null);
            } else {
                result.notImplemented();
            }
        } else if (call.method.equals("openChatboxFromNotification")) {
            if (activity != null) {
                boolean opened = CrispNotificationClient.openChatbox(activity, activity.getIntent());
                result.success(opened);
            } else {
                result.success(false);
            }
        } else if (call.method.equals("isVideoCallsSupported")) {
            result.success(false);
        } else if (call.method.equals("pushSessionEvent")) {
            HashMap<String, Object> args = (HashMap<String, Object>) call.arguments;

            if (args != null) {
                String name = (String) args.get("name");
                if (name == null || name.isEmpty()) {
                    result.error("INVALID_ARGUMENTS", "Missing 'name' argument", null);
                    return;
                }

                String colorString = (String) args.get("color");
                Color eventColor = parseColorOrDefault(colorString, Color.BLUE);

                im.crisp.client.external.data.SessionEvent event =
                        new im.crisp.client.external.data.SessionEvent(name, eventColor);

                Crisp.pushSessionEvent(event);
                result.success(null);
            } else {
                result.error("INVALID_ARGUMENTS", "Arguments must be a map", null);
            }
        } else if (call.method.equals("openHelpdesk")) {
            HashMap<String, Object> args = (HashMap<String, Object>) call.arguments;
            if (args != null) {
                String websiteId = (String) args.get("websiteId");
                if (websiteId == null || websiteId.trim().isEmpty()) {
                    result.error("INVALID_ARGUMENTS", "Missing or empty 'websiteId'", null);
                    return;
                }
                Crisp.configure(context, websiteId.trim());
                Crisp.searchHelpdesk(context);
                openActivity();
                result.success(null);
            } else {
                result.error("INVALID_ARGUMENTS", "Arguments must be a map", null);
            }
        } else if (call.method.equals("openHelpdeskArticle")) {
            HashMap<String, Object> args = (HashMap<String, Object>) call.arguments;
            if (args != null) {
                String websiteId = (String) args.get("websiteId");
                String locale = (String) args.get("locale");
                String slug = (String) args.get("slug");
                if (websiteId == null || websiteId.trim().isEmpty() || locale == null || slug == null) {
                    result.error("INVALID_ARGUMENTS", "Missing required arguments: 'websiteId', 'locale', 'slug'", null);
                    return;
                }
                String title = (String) args.get("title");
                String category = (String) args.get("category");
                Context articleContext = activity != null ? activity : context;
                Crisp.configure(context, websiteId.trim());
                if (title != null && category != null) {
                    Crisp.openHelpdeskArticle(articleContext, locale, slug, title, category);
                } else if (title != null) {
                    Crisp.openHelpdeskArticle(articleContext, locale, slug, title);
                } else {
                    Crisp.openHelpdeskArticle(articleContext, locale, slug);
                }
                result.success(null);
            } else {
                result.error("INVALID_ARGUMENTS", "Arguments must be a map", null);
            }
        } else {
            result.notImplemented();
        }
    }

    private void setCrispData(Context context, CrispConfig config) {
        if (config.tokenId != null) {
            Crisp.setTokenID(context, config.tokenId);
        }
        if (config.sessionSegment != null) {
            Crisp.setSessionSegment(config.sessionSegment);
        }
        if (config.user != null) {
            if (config.user.nickName != null) {
                Crisp.setUserNickname(config.user.nickName);
            }
            if (config.user.email != null) {
                boolean result = config.user.signature != null
                        ? Crisp.setUserEmail(config.user.email, config.user.signature)
                        : Crisp.setUserEmail(config.user.email);
                if(!result){
                    Log.d("CRSIP_CHAT","Email not set");
                }
            }
            if (config.user.avatar != null) {
               boolean result = Crisp.setUserAvatar(config.user.avatar);
               if(!result){
                   Log.d("CRSIP_CHAT","Avatar not set");
               }
            }
            if (config.user.phone != null) {
                boolean result =  Crisp.setUserPhone(config.user.phone);
                if(!result){
                    Log.d("CRSIP_CHAT","Phone not set");
                }
            }
            if (config.user.company != null) {
                Crisp.setUserCompany(config.user.company.toCrispCompany());
            }
        }

    }

    ///[openActivity] is opening ChatView Activity of CrispChat SDK.
    private void openActivity() {
        Intent intent = new Intent(context, ChatActivity.class);
        if (activity != null) {
            activity.startActivity(intent);
        } else {
            context.startActivity(intent);
        }
    }

    private Color parseColorOrDefault(String colorString, Color defaultColor) {
        if (colorString == null) {
            return defaultColor;
        }

        String safeColor = colorString.toLowerCase(Locale.ROOT);

        switch (safeColor) {
            case "black": return Color.BLACK;
            case "blue": return Color.BLUE;
            case "brown": return Color.BROWN;
            case "green": return Color.GREEN;
            case "grey":
            case "gray": return Color.GREY;
            case "orange": return Color.ORANGE;
            case "pink": return Color.PINK;
            case "purple": return Color.PURPLE;
            case "red": return Color.RED;
            case "yellow": return Color.YELLOW;
            default:
                Log.w("CrispSDK", "Unknown color: " + safeColor + ". Using default color.");
                return defaultColor;
        }
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
        context = null;
        activityBinding = null;
    }

}