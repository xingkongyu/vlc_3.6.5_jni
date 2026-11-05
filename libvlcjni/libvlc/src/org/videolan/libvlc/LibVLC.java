/*****************************************************************************
 * LibVLC.java
 *****************************************************************************
 * Copyright © 2010-2013 VLC authors and VideoLAN
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
 *****************************************************************************/

package org.videolan.libvlc;

import android.content.Context;
import android.util.Log;

import androidx.annotation.Nullable;

import org.videolan.libvlc.interfaces.AbstractVLCEvent;
import org.videolan.libvlc.interfaces.ILibVLC;
import org.videolan.libvlc.util.HWDecoderUtil;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.List;

@SuppressWarnings("unused, JniMissingFunction")
public class LibVLC extends VLCObject<ILibVLC.Event> implements ILibVLC {
    private static final String TAG = "VLC/LibVLC";

    final Context mAppContext;

    public static class Event extends AbstractVLCEvent {
        protected Event(int type) {
            super(type);
        }
    }

    /**
     * Create a LibVLC withs options
     *
     * @param options
     */
    public LibVLC(Context context, List<String> options) {
        mAppContext = context.getApplicationContext();
        loadLibraries();

        if (options == null)
            options = new ArrayList<>();
        boolean setAout = true, setChroma = true;
        // check if aout/vout options are already set
        for (String option : options) {
            if (option.startsWith("--aout="))
                setAout = false;
            if (option.startsWith("--android-display-chroma"))
                setChroma = false;
            if (!setAout && !setChroma)
                break;
        }

        // set aout/vout options if they are not set
        if (setAout || setChroma) {
            if (setAout) {
                final HWDecoderUtil.AudioOutput hwAout = HWDecoderUtil.getAudioOutputFromDevice();
                if (hwAout == HWDecoderUtil.AudioOutput.OPENSLES)
                    options.add("--aout=opensles");
                else
                    options.add("--aout=android_audiotrack");
            }
            if (setChroma) {
                options.add("--android-display-chroma");
                options.add("RV16");
            }
        }
        final String home = context.getDir("vlc", Context.MODE_PRIVATE).getAbsolutePath();
        // 预置字体与 fontconfig 缓存（见方法注释）：必须在 nativeNew 之前完成，
        // 因为 native 侧会据此 setenv FONTCONFIG_FILE。
        prepareFontCache(mAppContext, home);
        nativeNew(options.toArray(new String[options.size()]), home);
    }

    /**
     * 把 AAR 的 {@code assets/fonts} 复制到应用私有目录（{@code <home>/fonts}）。
     * <p>
     * 用于把随包附带的子集字体与系统字体分开管理：目标文件已存在且非空时不重复拷贝，
     * 因此在每次进程启动时调用一次的开销可以忽略。
     */
    private static void prepareFontDir(Context context, String home) {
        File dir = new File(home, "fonts");
        if (!dir.exists() && !dir.mkdirs())
            return;

        String[] names = null;
        try {
            names = context.getAssets().list("fonts");
        } catch (IOException ignored) {
        }
        if (names == null)
            return;

        for (String name : names) {
            File dst = new File(dir, name);
            if (dst.exists() && dst.length() != 0)
                continue;
            InputStream is = null;
            OutputStream os = null;
            try {
                is = context.getAssets().open("fonts/" + name);
                os = new FileOutputStream(dst);
                byte[] buf = new byte[65536];
                int n;
                while ((n = is.read(buf)) > 0)
                    os.write(buf, 0, n);
            } catch (IOException ignored) {
            } finally {
                try {
                    if (is != null)
                        is.close();
                } catch (IOException ignored) {
                }
                try {
                    if (os != null)
                        os.close();
                } catch (IOException ignored) {
                }
            }
        }
    }

    /**
     * 预置 fontconfig 字体缓存：把 AAR 的 {@code assets/fontconfig} 复制到
     * {@code <home>/fontconfig}，并顺带准备私有字体目录。
     * <p>
     * 背景：Android 没有 /etc/fonts/fonts.conf，fontconfig 首次运行会全量扫描系统字体
     * 并重建缓存（实测可阻塞数十秒，是首播黑屏/卡顿的根因之一）。把预先在设备上生成的
     * 缓存随包带过来，命中后即可跳过扫描。
     */
    private static void prepareFontCache(Context context, String home) {
        prepareFontDir(context, home);

        File fcDir = new File(home, "fontconfig");
        if (!fcDir.exists() && !fcDir.mkdirs())
            return;

        String[] names;
        try {
            names = context.getAssets().list("fontconfig");
        } catch (IOException e) {
            return;
        }
        if (names == null)
            return;

        for (String name : names) {
            File dst = new File(fcDir, name);
            if (dst.exists() && dst.length() > 0)
                continue;
            InputStream is = null;
            OutputStream os = null;
            try {
                is = context.getAssets().open("fontconfig/" + name);
                os = new FileOutputStream(dst);
                byte[] buf = new byte[8192];
                int n;
                while ((n = is.read(buf)) > 0)
                    os.write(buf, 0, n);
            } catch (IOException ignored) {
            } finally {
                try {
                    if (is != null)
                        is.close();
                } catch (IOException ignored) {
                }
                try {
                    if (os != null)
                        os.close();
                } catch (IOException ignored) {
                }
            }
        }
    }

    /**
     * Create a LibVLC
     */
    public LibVLC(Context context) {
        this(context, null);
    }

    /**
     * Get the libVLC version
     *
     * @return the libVLC version string
     */
    public static native String version();

    /**
     * Get the libVLC major version
     *
     * @return the libVLC major version, always >= 3
     */
    public static native int majorVersion();

    /**
     * Get the libVLC compiler
     *
     * @return the libVLC compiler string
     */
    public static native String compiler();

    /**
     * Get the libVLC changeset
     *
     * @return the libVLC changeset string
     */
    public static native String changeset();

    @Override
    protected ILibVLC.Event onEventNative(int eventType, long arg1, long arg2, float argf1, @Nullable String args1) {
        return null;
    }

    @Override
    public Context getAppContext() {
        return mAppContext;
    }

    @Override
    protected void onReleaseNative() {
        nativeRelease();
    }

    /**
     * Sets the application name. LibVLC passes this as the user agent string
     * when a protocol requires it.
     *
     * @param name human-readable application name, e.g. "FooBar player 1.2.3"
     * @param http HTTP User Agent, e.g. "FooBar/1.2.3 Python/2.6.0"
     */
    public void setUserAgent(String name, String http) {
        nativeSetUserAgent(name, http);
    }

    /* JNI */
    private native void nativeNew(String[] options, String homePath);

    private native void nativeRelease();

    private native void nativeSetUserAgent(String name, String http);

    private static boolean sLoaded = false;

    public static synchronized void loadLibraries() {
        if (sLoaded)
            return;
        sLoaded = true;

        try {
            System.loadLibrary("c++_shared");
        } catch (UnsatisfiedLinkError ule) {
            Log.e(TAG, "Can't load c++_shared library");
        } catch (SecurityException se) {
            Log.e(TAG, "Encountered a security issue when loading c++_shared library");
        }

        try {
            System.loadLibrary("vlc");
            System.loadLibrary("vlcjni");
        } catch (UnsatisfiedLinkError ule) {
            Log.e(TAG, "Can't load vlcjni library: " + ule);
            /// FIXME Alert user
            System.exit(1);
        } catch (SecurityException se) {
            Log.e(TAG, "Encountered a security issue when loading vlcjni library: " + se);
            /// FIXME Alert user
            System.exit(1);
        }
    }
}
