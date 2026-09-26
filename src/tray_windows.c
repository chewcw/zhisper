#include <windows.h>
#include <shellapi.h>
#include <objidl.h>
#include <wincodec.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

typedef struct ZhisperTray {
    HWND window;
    NOTIFYICONDATAW notify;
    HICON icons[3];
    UINT taskbar_created;
    int current_state;
    int com_initialized;
} ZhisperTray;

void zhisper_tray_destroy(ZhisperTray *tray);

static const wchar_t *const tooltips[3] = {
    L"zhisper: idle",
    L"zhisper: recording",
    L"zhisper: processing",
};

static BOOL add_notify_icon(ZhisperTray *tray) {
    tray->notify.uFlags = NIF_ICON | NIF_TIP;
    tray->notify.hIcon = tray->icons[tray->current_state];
    wcscpy_s(tray->notify.szTip, sizeof(tray->notify.szTip) / sizeof(wchar_t), tooltips[tray->current_state]);
    return Shell_NotifyIconW(NIM_ADD, &tray->notify);
}

static LRESULT CALLBACK tray_window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    ZhisperTray *tray = (ZhisperTray *)GetWindowLongPtrW(window, GWLP_USERDATA);
    if (tray != NULL && message == tray->taskbar_created) {
        add_notify_icon(tray);
        return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}

static HICON create_hicon_from_bgra(const BYTE *pixels, UINT width, UINT height) {
    BITMAPINFO bitmap_info = {0};
    bitmap_info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bitmap_info.bmiHeader.biWidth = (LONG)width;
    bitmap_info.bmiHeader.biHeight = -(LONG)height;
    bitmap_info.bmiHeader.biPlanes = 1;
    bitmap_info.bmiHeader.biBitCount = 32;
    bitmap_info.bmiHeader.biCompression = BI_RGB;

    HDC screen = GetDC(NULL);
    void *bits = NULL;
    HBITMAP color = CreateDIBSection(screen, &bitmap_info, DIB_RGB_COLORS, &bits, NULL, 0);
    ReleaseDC(NULL, screen);
    if (color == NULL || bits == NULL) {
        if (color != NULL) DeleteObject(color);
        return NULL;
    }

    memcpy(bits, pixels, (size_t)width * height * 4);
    HBITMAP mask = CreateBitmap(width, height, 1, 1, NULL);
    if (mask == NULL) {
        DeleteObject(color);
        return NULL;
    }

    ICONINFO icon_info = {0};
    icon_info.fIcon = TRUE;
    icon_info.hbmColor = color;
    icon_info.hbmMask = mask;
    HICON icon = CreateIconIndirect(&icon_info);
    DeleteObject(color);
    DeleteObject(mask);
    return icon;
}

static HICON decode_png(const unsigned char *data, size_t data_len) {
    IWICImagingFactory *factory = NULL;
    IWICStream *stream = NULL;
    IWICBitmapDecoder *decoder = NULL;
    IWICBitmapFrameDecode *frame = NULL;
    IWICFormatConverter *converter = NULL;
    HICON icon = NULL;

    HRESULT hr = CoCreateInstance(
        &CLSID_WICImagingFactory,
        NULL,
        CLSCTX_INPROC_SERVER,
        &IID_IWICImagingFactory,
        (void **)&factory);
    if (FAILED(hr) || factory == NULL) goto cleanup;

    hr = factory->lpVtbl->CreateStream(factory, &stream);
    if (FAILED(hr) || stream == NULL) goto cleanup;
    hr = stream->lpVtbl->InitializeFromMemory(stream, (BYTE *)data, (DWORD)data_len);
    if (FAILED(hr)) goto cleanup;

    hr = factory->lpVtbl->CreateDecoderFromStream(
        factory, (IStream *)stream, NULL, WICDecodeMetadataCacheOnDemand, &decoder);
    if (FAILED(hr) || decoder == NULL) goto cleanup;
    hr = decoder->lpVtbl->GetFrame(decoder, 0, &frame);
    if (FAILED(hr) || frame == NULL) goto cleanup;

    hr = factory->lpVtbl->CreateFormatConverter(factory, &converter);
    if (FAILED(hr) || converter == NULL) goto cleanup;
    hr = converter->lpVtbl->Initialize(
        converter,
        (IWICBitmapSource *)frame,
        &GUID_WICPixelFormat32bppBGRA,
        WICBitmapDitherTypeNone,
        NULL,
        0.0,
        WICBitmapPaletteTypeCustom);
    if (FAILED(hr)) goto cleanup;

    UINT width = 0;
    UINT height = 0;
    hr = converter->lpVtbl->GetSize(converter, &width, &height);
    if (FAILED(hr) || width == 0 || height == 0) goto cleanup;

    const UINT stride = width * 4;
    const UINT buffer_size = stride * height;
    BYTE *pixels = (BYTE *)malloc(buffer_size);
    if (pixels == NULL) goto cleanup;
    hr = converter->lpVtbl->CopyPixels(converter, NULL, stride, buffer_size, pixels);
    if (SUCCEEDED(hr)) icon = create_hicon_from_bgra(pixels, width, height);
    free(pixels);

cleanup:
    if (converter != NULL) converter->lpVtbl->Release(converter);
    if (frame != NULL) frame->lpVtbl->Release(frame);
    if (decoder != NULL) decoder->lpVtbl->Release(decoder);
    if (stream != NULL) stream->lpVtbl->Release(stream);
    if (factory != NULL) factory->lpVtbl->Release(factory);
    return icon;
}

ZhisperTray *zhisper_tray_create(
    const unsigned char *idle_png,
    size_t idle_len,
    const unsigned char *recording_png,
    size_t recording_len,
    const unsigned char *working_png,
    size_t working_len) {
    ZhisperTray *tray = (ZhisperTray *)calloc(1, sizeof(ZhisperTray));
    if (tray == NULL) return NULL;

    HRESULT com_result = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    if (SUCCEEDED(com_result)) tray->com_initialized = 1;

    tray->icons[0] = decode_png(idle_png, idle_len);
    tray->icons[1] = decode_png(recording_png, recording_len);
    tray->icons[2] = decode_png(working_png, working_len);
    if (tray->icons[0] == NULL || tray->icons[1] == NULL || tray->icons[2] == NULL) {
        zhisper_tray_destroy(tray);
        return NULL;
    }

    HINSTANCE instance = GetModuleHandleW(NULL);
    const wchar_t *class_name = L"ZhisperTrayWindow";
    WNDCLASSW window_class = {0};
    window_class.lpfnWndProc = tray_window_proc;
    window_class.hInstance = instance;
    window_class.lpszClassName = class_name;
    if (RegisterClassW(&window_class) == 0 && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        zhisper_tray_destroy(tray);
        return NULL;
    }

    tray->window = CreateWindowExW(
        0,
        class_name,
        L"zhisper",
        0,
        0,
        0,
        0,
        0,
        HWND_MESSAGE,
        NULL,
        instance,
        NULL);
    if (tray->window == NULL) {
        zhisper_tray_destroy(tray);
        return NULL;
    }
    SetWindowLongPtrW(tray->window, GWLP_USERDATA, (LONG_PTR)tray);
    tray->taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");

    tray->notify.cbSize = sizeof(NOTIFYICONDATAW);
    tray->notify.hWnd = tray->window;
    tray->notify.uID = 1;
    tray->current_state = 0;
    if (!add_notify_icon(tray)) {
        zhisper_tray_destroy(tray);
        return NULL;
    }
    return tray;
}

int zhisper_tray_set_state(ZhisperTray *tray, int state) {
    if (tray == NULL || state < 0 || state > 2) return 0;
    tray->current_state = state;
    tray->notify.uFlags = NIF_ICON | NIF_TIP;
    tray->notify.hIcon = tray->icons[state];
    wcscpy_s(tray->notify.szTip, sizeof(tray->notify.szTip) / sizeof(wchar_t), tooltips[state]);
    return Shell_NotifyIconW(NIM_MODIFY, &tray->notify) ? 1 : 0;
}

void zhisper_tray_poll(ZhisperTray *tray) {
    if (tray == NULL) return;
    MSG message;
    while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE)) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
}

void zhisper_tray_destroy(ZhisperTray *tray) {
    if (tray == NULL) return;
    if (tray->window != NULL) {
        Shell_NotifyIconW(NIM_DELETE, &tray->notify);
        DestroyWindow(tray->window);
    }
    for (int i = 0; i < 3; i++) {
        if (tray->icons[i] != NULL) DestroyIcon(tray->icons[i]);
    }
    if (tray->com_initialized) CoUninitialize();
    free(tray);
}
