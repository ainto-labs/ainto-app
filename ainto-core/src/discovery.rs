//! macOS application discovery using Launch Services.
//!
//! Uses the undocumented `LSCopyAllApplicationURLs` API to enumerate all registered
//! applications. This private API has been stable since macOS 10.5 and is widely used
//! by launcher applications (Alfred, Raycast, etc.).
//!
//! Adapted from the original Ainto project (MIT license).

use core::{
    ffi::{CStr, c_void},
    mem,
    ptr::{self, NonNull},
};
use std::{
    env,
    path::{Path, PathBuf},
    sync::LazyLock,
};

use objc2::Message;
use objc2::rc::Retained;
use objc2_app_kit::{NSBitmapImageFileType, NSBitmapImageRep, NSImage, NSImageRep, NSWorkspace};
use objc2_foundation::{
    NSBundle, NSData, NSDictionary, NSNumber, NSSize, NSString, NSURL, ns_string,
};

use crate::search::AppEntry;

/// Function signature for `LSCopyAllApplicationURLs`.
type LSCopyAllApplicationURLsFn = unsafe extern "C" fn(out: *mut *const c_void) -> i32;

const LAUNCHSERVICES_PATH: &CStr =
    c"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/LaunchServices";

fn load_symbol() -> Option<LSCopyAllApplicationURLsFn> {
    let lib = unsafe {
        libc::dlopen(
            LAUNCHSERVICES_PATH.as_ptr(),
            libc::RTLD_NOW | libc::RTLD_LOCAL,
        )
    };

    let lib = NonNull::new(lib)?;

    unsafe { libc::dlerror() };

    let sym = unsafe { libc::dlsym(lib.as_ptr(), c"_LSCopyAllApplicationURLs".as_ptr()) };
    let sym = NonNull::new(sym)?;

    Some(unsafe { mem::transmute::<*mut c_void, LSCopyAllApplicationURLsFn>(sym.as_ptr()) })
}

// CoreFoundation C functions for CFArray iteration
unsafe extern "C" {
    fn CFArrayGetCount(array: *const c_void) -> isize;
    fn CFArrayGetValueAtIndex(array: *const c_void, idx: isize) -> *const c_void;
    fn CFRelease(cf: *const c_void);
    fn CFURLCopyFileSystemPath(url: *const c_void, style: u32) -> *const c_void;
    fn CFStringGetCString(s: *const c_void, buf: *mut u8, len: isize, enc: u32) -> bool;
    fn CFStringGetLength(s: *const c_void) -> isize;
}

const K_CFURL_POSIX_PATH_STYLE: u32 = 0;
const K_CFSTRING_ENCODING_UTF8: u32 = 0x08000100;

/// Retrieves URLs for all registered applications.
fn registered_app_urls() -> Option<Vec<PathBuf>> {
    static SYM: LazyLock<Option<LSCopyAllApplicationURLsFn>> = LazyLock::new(load_symbol);

    let sym = (*SYM)?;
    let mut array_ptr: *const c_void = ptr::null();

    let err = unsafe { sym(&mut array_ptr) };
    if err != 0 || array_ptr.is_null() {
        return None;
    }

    let count = unsafe { CFArrayGetCount(array_ptr) };
    let mut paths = Vec::with_capacity(count as usize);

    for i in 0..count {
        let url = unsafe { CFArrayGetValueAtIndex(array_ptr, i) };
        if url.is_null() {
            continue;
        }
        let cf_path = unsafe { CFURLCopyFileSystemPath(url, K_CFURL_POSIX_PATH_STYLE) };
        if cf_path.is_null() {
            continue;
        }
        let len = unsafe { CFStringGetLength(cf_path) };
        // UTF-8 can be up to 4 bytes per character
        let buf_size = (len * 4 + 1) as usize;
        let mut buf = vec![0u8; buf_size];
        let ok = unsafe {
            CFStringGetCString(
                cf_path,
                buf.as_mut_ptr(),
                buf_size as isize,
                K_CFSTRING_ENCODING_UTF8,
            )
        };
        unsafe { CFRelease(cf_path) };
        if ok {
            let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
            let s = String::from_utf8_lossy(&buf[..end]);
            paths.push(PathBuf::from(s.as_ref()));
        }
    }

    unsafe { CFRelease(array_ptr) };

    Some(paths)
}

/// Directories containing user-facing applications.
static USER_APP_DIRS: LazyLock<Vec<PathBuf>> = LazyLock::new(|| {
    let mut dirs = vec![
        PathBuf::from("/Applications/"),
        PathBuf::from("/System/Applications/"),
    ];
    if let Some(home) = env::var_os("HOME") {
        dirs.push(Path::new(&home).join("Applications/"));
    }
    dirs
});

fn is_in_user_app_directory(path: &Path) -> bool {
    USER_APP_DIRS.iter().any(|dir| path.starts_with(dir))
}

fn is_nested_inside_another_app(app_path: &Path) -> bool {
    let comps: Vec<_> = app_path.components().collect();
    for component in comps.iter().take(comps.len().saturating_sub(1)) {
        if let std::path::Component::Normal(name) = component {
            let n = name.to_string_lossy();
            if n.ends_with(".app") || n.ends_with(".bundle") || n.ends_with(".framework") {
                return true;
            }
        }
    }
    false
}

fn is_helper_location(path: &Path) -> bool {
    let s = path.to_string_lossy();
    s.contains("/Contents/Library/LoginItems/")
        || s.contains("/Contents/XPCServices/")
        || s.contains("/Contents/Helpers/")
        || s.contains("/Contents/Frameworks/")
        || s.contains("/Library/PrivilegedHelperTools/")
        // Exclude system internals and support bundles — user-facing apps
        // live in /Applications/, /System/Applications/, or ~/Applications/.
        || s.starts_with("/System/Library/")
        || s.starts_with("/Library/Apple/System/")
        || s.starts_with("/Library/Application Support/")
}

/// Extract app metadata from a bundle path.
fn query_app(path: &Path, store_icons: bool) -> Option<AppEntry> {
    if is_nested_inside_another_app(path) || is_helper_location(path) {
        return None;
    }

    let url = NSURL::fileURLWithPath(&NSString::from_str(&path.to_string_lossy()));
    let bundle = NSBundle::bundleWithURL(&url)?;
    let info = bundle.infoDictionary()?;

    let get_string = |key: &NSString| -> Option<String> {
        info.objectForKey(key)?
            .downcast::<NSString>()
            .ok()
            .map(|s| s.to_string())
    };

    let is_truthy = |key: &NSString| -> bool {
        info.objectForKey(key)
            .map(|v| {
                v.downcast_ref::<NSNumber>()
                    .is_some_and(|n| n.boolValue())
                    || v.downcast_ref::<NSString>()
                        .is_some_and(|s| s.to_string() == "1" || s.to_string().eq_ignore_ascii_case("YES"))
            })
            .unwrap_or(false)
    };

    // Filter out background-only apps (daemons, agents).
    if is_truthy(ns_string!("LSBackgroundOnly")) {
        return None;
    }

    // LSUIElement apps (menu bar apps like Hinto, Bartender, etc.) are kept
    // if they're in a user app directory OR have a category type (legitimate app).
    // System LSUIElement apps without a category are filtered out.
    if is_truthy(ns_string!("LSUIElement"))
        && !is_in_user_app_directory(path)
        && get_string(ns_string!("LSApplicationCategoryType")).is_none()
    {
        return None;
    }

    if !is_in_user_app_directory(path)
        && get_string(ns_string!("LSApplicationCategoryType")).is_none()
    {
        return None;
    }

    let name = get_string(ns_string!("CFBundleDisplayName"))
        .or_else(|| get_string(ns_string!("CFBundleName")))
        .or_else(|| {
            path.file_stem()
                .map(|s| s.to_string_lossy().into_owned())
        })?;

    let icon_png = if store_icons {
        icon_of_path(path.to_str().unwrap_or(""))
    } else {
        None
    };

    let bundle_id = get_string(ns_string!("CFBundleIdentifier"));

    Some(AppEntry {
        display_name: name.clone(),
        search_name: name.to_lowercase(),
        path: path.to_string_lossy().into_owned(),
        bundle_id,
        icon_png,
        ranking: 0,
        is_favourite: false,
    })
}

/// Get all installed applications.
pub fn get_installed_apps(store_icons: bool) -> Vec<AppEntry> {
        let paths = registered_app_urls().unwrap_or_else(|| {
        // Fallback: scan known directories
        let mut paths = Vec::new();
        for dir in USER_APP_DIRS.iter() {
            if let Ok(entries) = std::fs::read_dir(dir) {
                for entry in entries.flatten() {
                    let path = entry.path();
                    if path.extension().is_some_and(|e| e == "app") {
                        paths.push(path);
                    }
                }
            }
        }
        paths
    });

    let mut apps: Vec<AppEntry> = paths
        .iter()
        .filter_map(|path| query_app(path, store_icons))
        .collect();

    // Dedup by bundle_id: prefer /Applications/ path over build directories
    apps.sort_by_key(|a| if a.path.starts_with("/Applications/") { 0 } else { 1 });
    let mut seen_ids = std::collections::HashSet::new();
    apps.retain(|app| {
        match &app.bundle_id {
            Some(id) => seen_ids.insert(id.clone()),
            None => true, // keep apps without bundle ID
        }
    });

    apps
}

/// Extract app icon as PNG bytes.
pub fn icon_of_path(path: &str) -> Option<Vec<u8>> {
    objc2::rc::autoreleasepool(|_| -> Option<Vec<u8>> {
        let path_ns = NSString::from_str(path);
        let image = NSWorkspace::sharedWorkspace().iconForFile(&path_ns);
        let target: f64 = 256.0;

        let png_data: Retained<NSData> = (|| -> Option<_> {
            unsafe {
                let mut best_rep = None::<Retained<NSImageRep>>;
                let mut best_w = 0.0;
                let mut best_h = 0.0;
                let mut largest_rep = None::<Retained<NSImageRep>>;
                let mut largest_area = 0.0;
                let mut largest_w = 0.0;
                let mut largest_h = 0.0;

                for rep in image.representations().iter() {
                    let s = rep.size();
                    let (w, h) = (s.width, s.height);
                    let area = w * h;

                    if area > largest_area {
                        largest_area = area;
                        largest_rep = Some(rep.retain());
                        largest_w = w;
                        largest_h = h;
                    }

                    if w >= target && h >= target {
                        let best_area = best_w * best_h;
                        if best_rep.is_none() || area < best_area {
                            best_rep = Some(rep.retain());
                            best_w = w;
                            best_h = h;
                        }
                    }
                }

                let (rep, out_w, out_h) = if let Some(rep) = best_rep {
                    (rep, target, target)
                } else if let Some(rep) = largest_rep {
                    (rep, largest_w, largest_h)
                } else {
                    return None;
                };

                let new_image = NSImage::imageWithSize_flipped_drawingHandler(
                    NSSize::new(out_w, out_h),
                    false,
                    &block2::RcBlock::new(move |rect| {
                        rep.drawInRect(rect);
                        true.into()
                    }),
                );

                NSBitmapImageRep::imageRepWithData(&*new_image.TIFFRepresentation()?)?
                    .representationUsingType_properties(
                        NSBitmapImageFileType::PNG,
                        &NSDictionary::new(),
                    )
            }
        })()?;

        Some(png_data.to_vec())
    })
}
