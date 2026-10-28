#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include <cstring>

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  // Chụp màn hình để đính kèm vào tin nhắn (Dart: lib/ui/screen_grab.dart).
  GtkWindow* window;
  FlMethodChannel* shot_channel;
  gint shot_monitor;
  gboolean shot_overlay;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Kênh "flygo/screenshot": ẩn cửa sổ, chụp màn hình có con trỏ chuột (X11; Wayland thì phía Dart dùng
// xdg-desktop-portal), biến cửa sổ thành lớp phủ toàn màn hình trên cùng rồi trả lại như cũ.
static void shot_method_cb(FlMethodChannel* channel, FlMethodCall* call, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  GtkWindow* window = self->window;
  const gchar* method = fl_method_call_get_name(call);
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
  g_autoptr(FlMethodResponse) response = nullptr;
  if (strcmp(method, "hide") == 0) {
    GdkMonitor* monitor = nullptr;
#ifdef GDK_WINDOWING_X11
    if (GDK_IS_X11_DISPLAY(display)) {
      GdkDevice* pointer = gdk_seat_get_pointer(gdk_display_get_default_seat(display));
      gint x = 0, y = 0;
      gdk_device_get_position(pointer, nullptr, &x, &y);
      monitor = gdk_display_get_monitor_at_point(display, x, y);
    }
#endif
    GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window));
    if (monitor == nullptr && gdk_window != nullptr) monitor = gdk_display_get_monitor_at_window(display, gdk_window);
    self->shot_monitor = 0;
    for (gint i = 0; i < gdk_display_get_n_monitors(display); i++) {
      if (gdk_display_get_monitor(display, i) == monitor) self->shot_monitor = i;
    }
    gtk_widget_hide(GTK_WIDGET(window));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "capture") == 0) {
#ifdef GDK_WINDOWING_X11
    GdkMonitor* monitor = gdk_display_get_monitor(display, self->shot_monitor);
    if (GDK_IS_X11_DISPLAY(display) && monitor != nullptr) {
      GdkRectangle r;
      gdk_monitor_get_geometry(monitor, &r);
      g_autoptr(GdkPixbuf) pixbuf = gdk_pixbuf_get_from_window(gdk_get_default_root_window(), r.x, r.y, r.width, r.height);
      if (pixbuf != nullptr) {
        const gint w = gdk_pixbuf_get_width(pixbuf);
        const gint h = gdk_pixbuf_get_height(pixbuf);
        const gint channels = gdk_pixbuf_get_n_channels(pixbuf);
        const gint stride = gdk_pixbuf_get_rowstride(pixbuf);
        const guchar* src = gdk_pixbuf_read_pixels(pixbuf);
        const gsize size = static_cast<gsize>(w) * h * 4;
        guchar* px = static_cast<guchar*>(g_malloc(size));
        for (gint y = 0; y < h; y++) {
          const guchar* row = src + static_cast<gsize>(y) * stride;
          guchar* out = px + static_cast<gsize>(y) * w * 4;
          for (gint x = 0; x < w; x++) {
            out[x * 4 + 0] = row[x * channels + 0];
            out[x * 4 + 1] = row[x * channels + 1];
            out[x * 4 + 2] = row[x * channels + 2];
            out[x * 4 + 3] = 255;
          }
        }
        g_autoptr(FlValue) map = fl_value_new_map();
        fl_value_set_string_take(map, "rgba", fl_value_new_uint8_list(px, size));
        fl_value_set_string_take(map, "width", fl_value_new_int(w));
        fl_value_set_string_take(map, "height", fl_value_new_int(h));
        g_free(px);
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(map));
      }
    }
#endif
    if (response == nullptr) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new("unsupported", "direct capture unavailable", nullptr));
    }
  } else if (strcmp(method, "overlay") == 0) {
    self->shot_overlay = TRUE;
    gtk_window_set_keep_above(window, TRUE);
    gtk_window_fullscreen_on_monitor(window, gtk_window_get_screen(window), self->shot_monitor);
    gtk_widget_show(GTK_WIDGET(window));
    gtk_window_present(window);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "restore") == 0) {
    if (self->shot_overlay) {
      gtk_window_unfullscreen(window);
      gtk_window_set_keep_above(window, FALSE);
      self->shot_overlay = FALSE;
    }
    gtk_widget_show(GTK_WIDGET(window));
    gtk_window_present(window);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Flygo Chat");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Flygo Chat");
  }

  gtk_window_set_default_size(window, 1280, 720);
  // Mở to sẵn (phóng to cửa sổ) để thấy đủ 3 cột, khỏi phải kéo.
  gtk_window_maximize(window);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  self->window = window;
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->shot_channel = fl_method_channel_new(fl_engine_get_binary_messenger(fl_view_get_engine(view)),
                                             "flygo/screenshot", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->shot_channel, shot_method_cb, self, nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->shot_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
