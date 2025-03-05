/*
autoxjs_device.js
使用 Autox.js 编写的安卓自动更新状态脚本
by wyf9. all rights reserved. (?)
Co-authored-by: NyaOH-Nahida - 新增捕捉退出事件，将退出脚本状态上报到服务器。
*/

// config start
const API_URL = 'https://luochu-sleepy.hf.space/device/set'; // 你的完整 API 地址，以 `/device/set` 结尾
const SECRET = 'vsfQO5ueRz97vpIY'; // 你的 secret
const ID = 'a-device'; // 你的设备 id, 唯一
const SHOW_NAME = '一个设备'; // 你的设备名称, 将显示在网页上
const CHECK_INTERVAL = 3000; // 检查间隔 (毫秒, 1000ms=1s)
const SKIPPED_NAMES = ['系统界面', '系统界面组件', '手机管家', '平板管家', 'System UI', 'Security tools'] // 获取到的软件名包含列表中之一时忽略

// 媒体信息配置
const MEDIA_INFO_ENABLED = true; // 是否启用媒体信息获取
const MEDIA_INFO_MODE = 'prefix'; // 媒体信息显示模式: 'prefix', 'standalone', 'both'
const MEDIA_DEVICE_ID = 'android-media-device'; // 独立设备模式下的设备ID
const MEDIA_DEVICE_SHOW_NAME = '手机音乐'; // 独立设备模式下的显示名称
const MEDIA_PREFIX_MAX_LENGTH = 20; // 媒体信息前缀最大长度（超出部分将被截断）
// config end

auto.waitFor(); // 等待无障碍

// 替换了 secret 的日志, 同时添加前缀
function log(msg) {
    try {
        console.log(`[sleepyc] ${msg.replace(SECRET, '[REPLACED]')}`);
    } catch (e) {
        console.log(`[sleepyc] ${msg}`);
    }
}
function error(msg) {
    try {
        console.error(msg.replace(SECRET, '[REPLACED]'));
    } catch (e) {
        console.error(msg);
    }
}

var last_status = '';
// 全局变量追踪媒体信息状态
var last_media_playing = false;
var last_media_content = "";
// 添加广播接收器来获取媒体信息变化
var mediaReceiver = null;
var currentMediaInfo = {playing: false, title: "", artist: "", album: ""};

function setupMediaReceiver() {
    if (mediaReceiver) return;
    
    try {
        // 注册媒体广播接收器
        var IntentFilter = android.content.IntentFilter;
        var filter = new IntentFilter();
        
        // 添加媒体相关的广播Action
        filter.addAction("com.android.music.metachanged");
        filter.addAction("com.android.music.playstatechanged");
        filter.addAction("com.android.music.playbackcomplete");
        filter.addAction("android.intent.action.MEDIA_BUTTON");
        filter.addAction("com.htc.music.metachanged");
        filter.addAction("fm.last.android.metachanged");
        filter.addAction("com.sec.android.app.music.metachanged");
        filter.addAction("com.nullsoft.winamp.metachanged");
        filter.addAction("com.amazon.mp3.metachanged");
        filter.addAction("com.miui.player.metachanged");
        filter.addAction("com.real.IMP.metachanged");
        filter.addAction("com.sonyericsson.music.metachanged");
        filter.addAction("com.rdio.android.metachanged");
        filter.addAction("com.samsung.sec.android.MusicPlayer.metachanged");
        filter.addAction("com.andrew.apollo.metachanged");
        filter.addAction("com.spotify.music.metadatachanged");
        
        // 创建广播接收器 - 使用JavaAdapter而非extend方法
        mediaReceiver = new JavaAdapter(android.content.BroadcastReceiver, {
            onReceive: function(context, intent) {
                try {
                    var action = intent.getAction();
                    if (action && (action.indexOf("metachanged") >= 0 || action.indexOf("metadatachanged") >= 0)) {
                        var artist = intent.getStringExtra("artist");
                        var album = intent.getStringExtra("album");
                        var track = intent.getStringExtra("track");
                        var playing = true; // 大多数广播只会在播放时发送
                        
                        if (artist || track) {
                            currentMediaInfo = {
                                playing: playing,
                                title: track || "",
                                artist: artist || "",
                                album: album || ""
                            };
                            log("媒体信息更新: " + JSON.stringify(currentMediaInfo));
                        }
                    }
                } catch (e) {
                    error("处理媒体广播失败: " + e);
                }
            }
        });
        
        // 注册广播接收器 - 添加RECEIVER_NOT_EXPORTED标志
        try {
            // Android 12+ (API 31+) 需要指定广播接收器可见性
            context.registerReceiver(mediaReceiver, filter, null, null, context.RECEIVER_NOT_EXPORTED);
        } catch (e) {
            // 如果失败，回退到旧方法
            context.registerReceiver(mediaReceiver, filter);
        }
        
        log("媒体广播接收器已注册");
    } catch (e) {
        error("注册媒体广播接收器失败: " + e);
        // 设置空值以便后续方法生效
        mediaReceiver = null;
    }
}

// 在脚本开始时调用
setupMediaReceiver();

function get_media_info() {
    /*
    获取当前播放的媒体信息
    返回: [是否播放中, 标题, 艺术家, 专辑]
    */
    // 先检查广播接收器获取的信息
    if (currentMediaInfo.playing && (currentMediaInfo.title || currentMediaInfo.artist)) {
        log("通过广播接收器获取媒体信息");
        return [true, currentMediaInfo.title, currentMediaInfo.artist, currentMediaInfo.album];
    }

    // 如果广播接收器没有获取到信息，继续使用原有方法
    try {
        // 检查是否存在notifications对象
        if (!notifications) {
            error("notifications API不可用，请授予通知访问权限");
            return [false, "", "", ""];
        }

        // 尝试导入notifications模块（AutoXjs 4.x版本可能需要）
        if (typeof notifications.queryAll !== 'function') {
            // 尝试启用通知监听服务
            try {
                // 对于部分版本可能需要先启用通知监听
                notifications.requestPermission();
                notifications.observeNotification();
            } catch (e) {
                error("无法启用通知监听: " + e);
            }
        }

        // 获取当前通知
        let notifs = notifications.queryAll();
        if (!notifs) {
            error("获取通知列表失败，返回为空");
            return [false, "", "", ""];
        }

        for (let i = 0; i < notifs.length; i++) {
            let notification = notifs[i];

            // 检查通知是否包含媒体控制
            if (notification && notification.actions && notification.actions.length > 0) {
                // 查找典型的媒体控制操作如"暂停"
                let isMediaNotification = notification.actions.some(action =>
                    action && action.title &&
                    (action.title.toLowerCase().includes("暂停") ||
                        action.title.toLowerCase().includes("pause"))
                );

                if (isMediaNotification) {
                    // 提取媒体信息
                    let title = notification.title || "";
                    let text = notification.text || "";
                    let app = notification.packageName ? app.getAppName(notification.packageName) : "";

                    // 尝试从通知文本中提取艺术家和专辑信息
                    let artist = "";
                    let album = "";

                    if (text.includes(" - ")) {
                        let parts = text.split(" - ");
                        artist = parts[0] || "";
                        album = parts.length > 1 ? parts[1] : "";
                    }

                    return [true, title, artist, album];
                }
            }
        }
    } catch (e) {
        error("媒体通知获取失败: " + e);
    }

    // 备选方案：尝试使用媒体会话API（如果AutoXjs支持）
    try {
        let mediaSessionInfo = context.getSystemService(android.content.Context.MEDIA_SESSION_SERVICE);
        if (mediaSessionInfo) {
            let activeSessions = mediaSessionInfo.getActiveSessions(null);
            if (activeSessions && activeSessions.size() > 0) {
                let metadata = activeSessions.get(0).getMetadata();
                if (metadata) {
                    let title = metadata.getString(android.media.MediaMetadata.METADATA_KEY_TITLE) || "";
                    let artist = metadata.getString(android.media.MediaMetadata.METADATA_KEY_ARTIST) || "";
                    let album = metadata.getString(android.media.MediaMetadata.METADATA_KEY_ALBUM) || "";
                    return [true, title, artist, album];
                }
            }
        }
    } catch (e) {
        error("媒体API获取失败: " + e);
    }

    try {
        // 方法2：尝试使用媒体控制器（Android 5.0+）
        let mediaController = new android.media.session.MediaController(
            context,
            android.media.session.MediaSessionManager.getService()
                .getActiveSessions(new android.content.ComponentName(context, auto.service.getClass()))
                .get(0)
        );
        
        if (mediaController) {
            let metadata = mediaController.getMetadata();
            if (metadata) {
                let title = metadata.getString(android.media.MediaMetadata.METADATA_KEY_TITLE) || "";
                let artist = metadata.getString(android.media.MediaMetadata.METADATA_KEY_ARTIST) || "";
                return [true, title, artist, ""];
            }
        }
    } catch (e) {
        error("媒体控制器获取失败: " + e);
    }

    // try {
    //     // 方法3：检查正在运行的音乐播放器应用
    //     let musicApps = ["com.netease.cloudmusic", "com.tencent.qqmusic", 
    //                       "com.kugou.android", "com.ximalaya.ting.android",
    //                       "cmccwm.mobilemusic", "com.spotify.music"];
        
    //     let currentApp = currentPackage();
    //     for (let i = 0; i < musicApps.length; i++) {
    //         if (currentApp === musicApps[i]) {
    //             return [true, "正在使用" + app.getAppName(currentApp), "", ""];
    //         }
    //     }
    // } catch (e) {
    //     error("应用检测失败: " + e);
    // }

    // try {
    //     // 方法1：尝试获取音频焦点状态
    //     let audioManager = context.getSystemService(android.content.Context.AUDIO_SERVICE);
    //     if (audioManager && audioManager.isMusicActive()) {
    //         // 只能检测到音乐在播放，但无法获取具体信息
    //         return [true, "正在播放音乐", "", ""];
    //     }
    // } catch (e) {
    //     error("音频管理器检测失败: " + e);
    // }

    return [false, "", "", ""];
}

function check_status() {
    /*
    检查状态并返回 app_name (如 未亮屏/获取不到应用名 则返回空)
    [Tip] 如有调试需要可自行取消 log 注释
    */
    // log(`[check] screen status: ${device.isScreenOn()}`);
    if (!device.isScreenOn()) {
        return ('');
    }
    var app_package = currentPackage(); // 应用包名
    // log(`[check] app_package: '${app_package}'`);
    var app_name = app.getAppName(app_package); // 应用名称
    // log(`[check] app_name: '${app_name}'`);
    var battery = device.getBattery(); // 电池百分比
    // log(`[check] battery: ${battery}%`);
    // 构建返回名称
    var retname;
    // 判断设备充电状态
    if (device.isCharging()) {
        var retname = `[${battery}% +] ${app_name}`;
    } else {
        var retname = `[${battery}%] ${app_name}`;
    }

    // 添加媒体信息前缀（如果启用并检测到媒体）
    if (MEDIA_INFO_ENABLED && (MEDIA_INFO_MODE === 'prefix' || MEDIA_INFO_MODE === 'both')) {
        let [is_playing, title, artist, album] = get_media_info();
        if (is_playing && title) {
            let media_prefix = "";
            // 如果标题太长，进行截断
            if (title.length > MEDIA_PREFIX_MAX_LENGTH - 4) {
                media_prefix = `[♪${title.substring(0, MEDIA_PREFIX_MAX_LENGTH - 7)}...]`;
            } else {
                media_prefix = `[♪${title}]`;
            }
            retname = `${media_prefix} ${retname}`;
        }
    }

    if (!app_name) {
        retname = '';
    }
    return (retname);
}
function send_status() {
    /*
    发送 check_status() 的返回
    */
    var app_name = check_status();
    log(`ret app_name: '${app_name}'`);

    // 判断是否与上次相同
    if (app_name == last_status) {
        log('same as last status, bypass request');
        return;
    }

    // 判断是否在忽略列表中
    for (let i = 0; i < SKIPPED_NAMES.length; i++) {
        if (app_name.includes(SKIPPED_NAMES[i])) {
            log(`bypass because of: '${SKIPPED_NAMES[i]}'`);
            return;
        }
    }

    last_status = app_name;
    // 判断 using
    if (app_name == '') {
        log('using: false');
        var using = false;
    } else {
        log('using: true');
        var using = true;
    }

    // POST to api
    log(`Status string: '${app_name}'`);
    log(`POST ${API_URL}`);
    r = http.postJson(API_URL, {
        'secret': SECRET,
        'id': ID,
        'show_name': SHOW_NAME,
        'using': using,
        'app_name': app_name
    });
    log(`response: ${r.body.string()}`);
}

function update_media_device() {
    /*
    更新媒体信息（独立设备模式）
    */
    if (!MEDIA_INFO_ENABLED || (MEDIA_INFO_MODE !== 'standalone' && MEDIA_INFO_MODE !== 'both')) {
        return;
    }

    try {
        // 获取媒体信息
        let [is_playing, title, artist, album] = get_media_info();

        // 构建媒体信息
        let standalone_media_info = "";
        let current_media_playing = false;

        if (is_playing && (title || artist)) {
            current_media_playing = true;
            let parts = [];

            if (title) {
                parts.push(`♪${title}`);
            }
            if (artist) {
                parts.push(artist);
            }
            if (album) {
                parts.push(album);
            }

            standalone_media_info = parts.length > 0 ? parts.join("-") : "♪播放中";
        }

        // 判断是否需要更新
        let media_changed = (current_media_playing !== last_media_playing) ||
            (current_media_playing && standalone_media_info !== last_media_content);

        if (media_changed) {
            log(`Media changed: status ${last_media_playing}->${current_media_playing}, content changed: ${last_media_content !== standalone_media_info}`);

            if (current_media_playing) {
                // 从不播放变为播放或歌曲内容变化
                let r = http.postJson(API_URL, {
                    'secret': SECRET,
                    'id': MEDIA_DEVICE_ID,
                    'show_name': MEDIA_DEVICE_SHOW_NAME,
                    'using': true,
                    'app_name': standalone_media_info
                });
                log(`Media Response: ${r.statusCode}`);
            } else {
                // 从播放变为不播放
                let r = http.postJson(API_URL, {
                    'secret': SECRET,
                    'id': MEDIA_DEVICE_ID,
                    'show_name': MEDIA_DEVICE_SHOW_NAME,
                    'using': false,
                    'app_name': 'No Media Playing'
                });
                log(`Media Response: ${r.statusCode}`);
            }

            // 更新上次的媒体状态和内容
            last_media_playing = current_media_playing;
            last_media_content = standalone_media_info;
        }
    } catch (e) {
        error(`Media Info Error: ${e}`);
    }
}


// 程序退出后上报停止事件
events.on("exit", function () {
    log("Script exits, uploading using = false");
    toast("[sleepy] 脚本已停止, 上报中");
    // POST to api
    log(`POST ${API_URL}`);
    try {
        if (mediaReceiver) {
            context.unregisterReceiver(mediaReceiver);
            log("媒体广播接收器已注销");
        }
    } catch (e) {
        error("注销媒体广播接收器失败: " + e);
    }
    try {
        r = http.postJson(API_URL, {
            'secret': SECRET,
            'id': ID,
            'show_name': SHOW_NAME,
            'using': false,
            'app_name': '[Client Exited]' // using 为 false 时前端不会显示这个, 而是 '未在使用'
        });
        log(`response: ${r.body.string()}`);

        // 如果启用了独立媒体设备，也发送该设备的退出状态
        if (MEDIA_INFO_ENABLED && (MEDIA_INFO_MODE === 'standalone' || MEDIA_INFO_MODE === 'both')) {
            r = http.postJson(API_URL, {
                'secret': SECRET,
                'id': MEDIA_DEVICE_ID,
                'show_name': MEDIA_DEVICE_SHOW_NAME,
                'using': false,
                'app_name': 'Media Client Exited'
            });
            log(`Media exit response: ${r.body.string()}`);
        }

        toast("[sleepy] 上报成功");
    } catch (e) {
        error(`Error when uploading: ${e}`);
        toast(`[sleepy] 上报失败! 请检查控制台日志`);
    }
});

while (true) {
    log('---------- Run\n');
    try {
        send_status();
        update_media_device(); // 确保媒体信息也会被更新
    } catch (e) {
        error(`ERROR sending status: ${e}`);
    }
    sleep(CHECK_INTERVAL);
}
