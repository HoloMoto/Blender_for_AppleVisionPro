/* SPDX-FileCopyrightText: 2001-2002 NaN Holding BV. All rights reserved.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup creator
 */

#include <cstdlib>
#include <cstring>

#ifdef WIN32
#  include "utfconv.hh"
#  include <windows.h>
#  ifdef WITH_CPU_CHECK
#    pragma comment(linker, "/include:cpu_check_win32")
#  endif
#endif

#if defined(WITH_TBB_MALLOC) && defined(_MSC_VER) && defined(NDEBUG)
#  pragma comment(lib, "tbbmalloc_proxy.lib")
#  pragma comment(linker, "/include:__TBB_malloc_proxy")
#endif

#include "MEM_guardedalloc.h"

#include "CLG_log.h"

#include "DNA_genfile.h"

#include "BLI_endian_defines.h"
#include "BLI_fileops.h"
#include "BLI_fftw.hh"
#include "BLI_path_utils.hh"
#include "BLI_string.h"
#include "BLI_system.h"
#include "BLI_task.h"
#include "BLI_threads.h"
#include "BLI_utildefines.h"

/* Mostly initialization functions. */
#include "BKE_appdir.hh"
#include "BKE_blender.hh"
#include "BKE_blender_version.h"
#include "BKE_brush.hh"
#include "BKE_callbacks.hh"
#include "BKE_context.hh"
#include "BKE_cpp_types.hh"
#include "BKE_global.hh"
#include "BKE_idtype.hh"
#include "BKE_material.hh"
#include "BKE_modifier.hh"
#include "BKE_node.hh"
#include "BKE_particle.h"
#include "BKE_shader_fx.h"
#include "BKE_sound.h"
#include "BKE_vfont.hh"
#include "BKE_volume.hh"

#ifndef WITH_PYTHON_MODULE
#  include "BLI_args.h"
#endif

#include "DEG_depsgraph.hh"

#include "IMB_imbuf.hh" /* For #IMB_init. */

#include "MOV_util.hh"

#include "RE_engine.h"
#include "RE_texture.h"

#include "ED_datafiles.h"

#include "SEQ_modifier.hh"

#include "WM_api.hh"

#include "RNA_define.hh"

#ifdef WITH_OPENGL_BACKEND
#  include "GPU_compilation_subprocess.hh"
#endif

#ifdef WITH_FREESTYLE
#  include "FRS_freestyle.h"
#endif

#include <csignal>

#ifdef __FreeBSD__
#  include <floatingpoint.h>
#endif

#ifdef WITH_BINRELOC
#  include "binreloc.h"
#endif

#ifdef WITH_LIBMV
#  include "libmv-capi.h"
#endif

#ifdef WITH_CYCLES
#  include "CCL_api.h"
#endif

#include "creator_intern.h" /* Own include. */

BLI_STATIC_ASSERT(ENDIAN_ORDER == L_ENDIAN, "Blender only builds on little endian systems")

void WM_main_entry(bContext *C);
int GHOST_iosmain(int argc, const char **argv);
void GHOST_iosfinalize(bContext *C);

#ifdef WITH_APPLE_CROSSPLATFORM
extern "C" void GHOST_IOS_pump_main_runloop(void);
extern "C" void GHOST_IOS_yield_main_runloop(void);
extern "C" void GHOST_IOS_schedule_on_main(void (*fn)(void *userdata), void *userdata);
extern "C" void GHOST_IOS_schedule_on_main_after(void (*fn)(void *userdata),
                                                 void *userdata,
                                                 double delay_seconds);
extern "C" void GHOST_IOS_notify_launch_ui_ready(void);
extern "C" void GHOST_IOS_diag_log(const char *message);

static void ios_diag(const char *msg)
{
  GHOST_IOS_diag_log(msg);
}

/* Lightweight checkpoint: log only. Nested CFRunLoop yields burn the launch
 * watchdog budget and do not reset it on TestFlight. */
static void ios_step(const char *msg)
{
  GHOST_IOS_diag_log(msg);
}

static void configure_ios_bundle_resource_envvars()
{
  const char *program_dir = BKE_appdir_program_dir();
  if (program_dir == nullptr || program_dir[0] == '\0') {
    return;
  }

  char assets_root[FILE_MAX];
  char datafiles_dir[FILE_MAX];
  char scripts_dir[FILE_MAX];
  char python_dir[FILE_MAX];
  char blender_version_str[16];

  SNPRINTF(blender_version_str, "%d.%d", BLENDER_VERSION / 100, BLENDER_VERSION % 100);
  BLI_path_join(assets_root, sizeof(assets_root), program_dir, "Assets", blender_version_str);
  BLI_path_join(datafiles_dir, sizeof(datafiles_dir), assets_root, "datafiles");
  BLI_path_join(scripts_dir, sizeof(scripts_dir), assets_root, "scripts");
  BLI_path_join(python_dir, sizeof(python_dir), assets_root, "python");

  if (BLI_is_dir(assets_root)) {
    BLI_setenv("BLENDER_SYSTEM_RESOURCES", assets_root);
  }
  if (BLI_is_dir(datafiles_dir)) {
    /* Always set (not if_new): a stale/wrong env would hide Essentials brushes. */
    BLI_setenv("BLENDER_SYSTEM_DATAFILES", datafiles_dir);

    /* Hint for tools that re-read env; Plug_InitConfig itself already ran at
     * libusd_ms load. USD_platform_runtime_init() also RegisterPlugins(). */
    char usd_plugin_dir[FILE_MAX];
    BLI_path_join(usd_plugin_dir, sizeof(usd_plugin_dir), datafiles_dir, "usd");
    if (BLI_is_dir(usd_plugin_dir)) {
      BLI_setenv("PXR_PLUGINPATH_NAME", usd_plugin_dir);
    }
  }
  if (BLI_is_dir(scripts_dir)) {
    BLI_setenv("BLENDER_SYSTEM_SCRIPTS", scripts_dir);
  }
  if (BLI_is_dir(python_dir)) {
    BLI_setenv("BLENDER_SYSTEM_PYTHON", python_dir);
  }
}
#endif

/* -------------------------------------------------------------------- */
/** \name Local Defines
 * \{ */

/* When building as a Python module, don't use special argument handling
 * so the module loading logic can control the `argv` & `argc`. */
#if defined(WIN32) && !defined(WITH_PYTHON_MODULE)
#  define USE_WIN32_UNICODE_ARGS
#endif

/** \} */

/* -------------------------------------------------------------------- */
/** \name Local Application State
 * \{ */

/* Written to by `creator_args.cc`. */
ApplicationState app_state = []() {
  ApplicationState app_state{};
  app_state.signal.use_crash_handler = true;
  app_state.signal.use_abort_handler = true;
  app_state.exit_code_on_error.python = 0;
  app_state.main_arg_deferred = nullptr;
  return app_state;
}();

/** \} */

/* -------------------------------------------------------------------- */
/** \name Application Level Callbacks
 *
 * Initialize callbacks for the modules that need them.
 * \{ */

static void callback_mem_error(const char *errorStr)
{
  fputs(errorStr, stderr);
  fflush(stderr);
}

static void main_callback_setup()
{
  /* Error output from the guarded allocation routines. */
  MEM_set_error_callback(callback_mem_error);
}

/** Data to free when Blender exits early on. */
struct CreatorAtExitData_EarlyExit {
  bContext *C;
};

/** Free data on early exit (if Python calls `sys.exit()` while parsing args for eg). */
struct CreatorAtExitData {
#ifndef WITH_PYTHON_MODULE
  bArgs *ba;
#endif

#ifdef USE_WIN32_UNICODE_ARGS
  char **argv;
  int argv_num;
#endif

  /**
   * When non-null, run additional exit logic.
   * Cleared once early initialization is over.
   */
  CreatorAtExitData_EarlyExit *early_exit = nullptr;
};

static void callback_main_atexit(void *user_data)
{
  CreatorAtExitData *app_init_data = static_cast<CreatorAtExitData *>(user_data);

#ifndef WITH_PYTHON_MODULE
  if (app_init_data->ba) {
    BLI_args_destroy(app_init_data->ba);
    app_init_data->ba = nullptr;
  }
#endif

#ifdef USE_WIN32_UNICODE_ARGS
  if (app_init_data->argv) {
    while (app_init_data->argv_num) {
      free((void *)app_init_data->argv[--app_init_data->argv_num]);
    }
    free((void *)app_init_data->argv);
    app_init_data->argv = nullptr;
  }
#endif

  if (CreatorAtExitData_EarlyExit *early_exit = app_init_data->early_exit) {
    CTX_free(early_exit->C);

    DEG_free_node_types();

    BKE_blender_globals_clear();
    BKE_appdir_exit();

    DNA_sdna_current_free();

    CLG_exit();
  }
}

static void callback_clg_fatal(void *fp)
{
  BLI_system_backtrace(static_cast<FILE *>(fp));
}

#ifdef WITH_APPLE_CROSSPLATFORM
/**
 * Heap state so startup can return to the *system* main runloop between stages.
 * Nested CFRunLoopRunInMode does NOT reset the visionOS/TestFlight launch watchdog.
 */
struct IosLaunchState {
  bContext *C = nullptr;
#  ifndef WITH_PYTHON_MODULE
  bArgs *ba = nullptr;
#  endif
  int argc = 0;
  const char **argv = nullptr;
  CreatorAtExitData app_init_data = {nullptr};
};

static IosLaunchState *g_ios_launch = nullptr;

static void ios_launch_finish(void *userdata);
static void ios_launch_wm(void *userdata);
static void ios_launch_first_refresh(void *userdata);

static void ios_launch_rna_step(void *userdata)
{
  IosLaunchState *st = static_cast<IosLaunchState *>(userdata);
  static int batch = 0;
  /* prop_lookup_set skipped on visionOS — batches are cheap; still delay so the
   * launch watchdog sees frames. Died at ~1408 while allocating lookup sets. */
  const bool done = RNA_init_async_step(128);
  batch += 1;
  if ((batch % 4) == 0 || done) {
    char buf[160];
    snprintf(buf,
             sizeof(buf),
             "creator: RNA_init async batch %d structs=%d done=%d",
             batch,
             RNA_init_async_progress(),
             int(done));
    ios_diag(buf);
  }
  if (!done) {
    GHOST_IOS_schedule_on_main_after(ios_launch_rna_step, st, 0.016);
    return;
  }
  ios_diag("creator: after RNA_init");
  GHOST_IOS_schedule_on_main_after(ios_launch_finish, st, 0.016);
}

static void ios_launch_finish(void *userdata)
{
  IosLaunchState *st = static_cast<IosLaunchState *>(userdata);

  RE_texture_rng_init();
  ios_diag("creator: after RE_texture_rng_init");
  RE_engines_init();
  ios_diag("creator: after RE_engines_init");
  blender::bke::node_system_init();
  ios_diag("creator: after node_system_init");

  BKE_brush_system_init();
  BKE_particle_init_rng();
  ios_diag("creator: after engines/nodes/brush init");

  /* Next main-queue turn before WM_init (often the next long stall). */
  GHOST_IOS_schedule_on_main_after(ios_launch_wm, st, 0.016);
}

static void ios_launch_wm(void *userdata)
{
  IosLaunchState *st = static_cast<IosLaunchState *>(userdata);
  bContext *C = st->C;
#  ifndef WITH_PYTHON_MODULE
  bArgs *ba = st->ba;
#  endif
  const int argc = st->argc;
  const char **argv = st->argv;
  CreatorAtExitData &app_init_data = st->app_init_data;

#  if defined(WITH_PYTHON_MODULE) || defined(WITH_HEADLESS)
  G.background = true;
  BKE_sound_force_device("None");
#  else
  if (G.background) {
    main_signal_setup_background();
  }
#  endif

  BKE_vfont_builtin_register(datatoc_bfont_pfb, datatoc_bfont_pfb_size);
  BKE_sound_init_once();
  BKE_materials_init();

#  ifndef WITH_PYTHON_MODULE
  if (G.background == 0) {
    BLI_args_parse(ba, ARG_PASS_SETTINGS_GUI, nullptr, nullptr);
  }
  BLI_args_parse(ba, ARG_PASS_SETTINGS_FORCE, nullptr, nullptr);
#  endif

  fprintf(stderr, "[ios] before WM_init\n");
  fflush(stderr);
  ios_diag("creator: before WM_init");
  WM_init(C, argc, argv);
  fprintf(stderr, "[ios] after WM_init\n");
  fflush(stderr);
  ios_diag("creator: after WM_init");

  /* Arm the MTKView draw loop BEFORE any further main-thread stalls.
   * drawInMTKView only runs WM_main_loop_body when global C is set; if we
   * call WM_main_entry first and it blocks, the UI freezes forever. */
  GHOST_iosfinalize(C);
  ios_diag("creator: after GHOST_iosfinalize (draw loop armed)");
  GHOST_IOS_notify_launch_ui_ready();

#  ifndef WITH_PYTHON
  printf(
      "\n* WARNING * - Blender compiled without Python!\n"
      "this is not intended for typical usage\n\n");
#  endif

#  ifdef WITH_FREESTYLE
  FRS_init();
  FRS_set_context(C);
#  endif

#  ifndef WITH_PYTHON_MODULE
  BLI_args_parse(ba, ARG_PASS_FINAL, main_args_handle_load_file, C);
#  endif

  callback_main_atexit(&app_init_data);
  BKE_blender_atexit_unregister(callback_main_atexit, &app_init_data);

#  ifndef WITH_PYTHON_MODULE
  ba = nullptr;
  st->ba = nullptr;
  (void)ba;
#  endif

#  ifndef WITH_PYTHON_MODULE
  if (G.background) {
    int exit_code;
    if (app_state.main_arg_deferred != nullptr) {
      exit_code = main_arg_deferred_handle();
      main_arg_deferred_free();
    }
    else {
      exit_code = G.is_break ? EXIT_FAILURE : EXIT_SUCCESS;
    }
    WM_exit(C, exit_code);
  }
  else {
    BLI_assert(app_state.main_arg_deferred == nullptr);
    WM_init_splash_on_startup(C);

    /* Return to the system runloop so MTKView can paint, then do the initial
     * depsgraph refresh on a later turn (avoids deadlock with the draw path). */
    ios_diag("creator: scheduling deferred WM_main_entry");
    GHOST_IOS_schedule_on_main_after(ios_launch_first_refresh, st, 0.1);
  }
#  endif /* !WITH_PYTHON_MODULE */
}

static void ios_launch_first_refresh(void *userdata)
{
  IosLaunchState *st = static_cast<IosLaunchState *>(userdata);
  bContext *C = st->C;
  ios_diag("creator: before WM_main_entry");
  WM_main_entry(C);
  ios_diag("creator: after WM_main_entry");
}
#endif /* WITH_APPLE_CROSSPLATFORM */

/** \} */

/* -------------------------------------------------------------------- */
/** \name Blender as a Stand-Alone Python Module (bpy)
 *
 * While not officially supported, this can be useful for Python developers.
 * See: https://developer.blender.org/docs/handbook/building_blender/python_module/
 * \{ */

#ifdef WITH_PYTHON_MODULE

/* Called in `bpy_interface.cc` when building as a Python module. */
int main_python_enter(int argc, const char **argv);
void main_python_exit();

/* Rename the `main(..)` function, allowing Python initialization to call it. */
#  define main main_python_enter
static void *evil_C = nullptr;

#  ifdef __APPLE__
/* Environment is not available in macOS shared libraries. */
#    include <crt_externs.h>
char **environ = nullptr;
#  endif /* __APPLE__ */

#endif /* WITH_PYTHON_MODULE */

/** \} */

/* -------------------------------------------------------------------- */
/** \name GMP Allocator Workaround
 * \{ */

#if (defined(WITH_TBB_MALLOC) && defined(_MSC_VER) && defined(NDEBUG) && defined(WITH_GMP)) || \
    defined(DOXYGEN)
#  include "gmp.h"
#  include "tbb/scalable_allocator.h"

void *gmp_alloc(size_t size)
{
  return scalable_malloc(size);
}
void *gmp_realloc(void *ptr, size_t /*old_size*/, size_t new_size)
{
  return scalable_realloc(ptr, new_size);
}

void gmp_free(void *ptr, size_t /*size*/)
{
  scalable_free(ptr);
}
/**
 * Use TBB's scalable_allocator on Windows.
 * `TBBmalloc` correctly captures all allocations already,
 * however, GMP is built with MINGW since it doesn't build with MSVC,
 * which TBB has issues hooking into automatically.
 */
void gmp_blender_init_allocator()
{
  mp_set_memory_functions(gmp_alloc, gmp_realloc, gmp_free);
}
#endif

/** \} */

/* -------------------------------------------------------------------- */
/** \name Main Function
 * \{ */

#if defined(__APPLE__)
extern "C" int GHOST_HACK_getFirstFile(char buf[]);
#endif

/**
 * Blender's main function responsibilities are:
 * - setup subsystems.
 * - handle arguments.
 * - run #WM_main() event loop,
 *   or exit immediately when running in background-mode.
 */

#ifdef WITH_APPLE_CROSSPLATFORM
#  ifndef WITH_VISIONOS_SWIFT_MAIN
int main(int argc, const char **argv)
{
  return GHOST_iosmain(argc, argv);
}
#  endif

int main_ios_callback(int argc, const char **argv)
#else
int main(int argc,
#  ifdef USE_WIN32_UNICODE_ARGS
         const char ** /*argv_c*/
#  else
         const char **argv
#  endif
)
#endif
{
  fprintf(stderr, "[ios] main_ios_callback begin\n");
  fflush(stderr);
#ifdef WITH_APPLE_CROSSPLATFORM
  ios_diag("creator: main_ios_callback begin");
#endif
  bContext *C;
#ifndef WITH_PYTHON_MODULE
  bArgs *ba;
#endif

  /* Ensure we free data on early-exit. */
  CreatorAtExitData app_init_data = {nullptr};
  BKE_blender_atexit_register(callback_main_atexit, &app_init_data);

  CreatorAtExitData_EarlyExit app_init_data_early_exit = {nullptr};
  app_init_data.early_exit = &app_init_data_early_exit;

/* Un-buffered `stdout` makes `stdout` and `stderr` better synchronized, and helps
 * when stepping through code in a debugger (prints are immediately
 * visible). However disabling buffering causes lock contention on windows
 * see #76767 for details, since this is a debugging aid, we do not enable
 * the un-buffered behavior for release builds. */
#ifndef NDEBUG
  setvbuf(stdout, nullptr, _IONBF, 0);
#endif

#ifdef WIN32
#  ifdef USE_WIN32_UNICODE_ARGS
  /* Win32 Unicode Arguments. */
  {
    /* NOTE: Can't use `guardedalloc` allocation here, as it's not yet initialized
     * (it depends on the arguments passed in, which is what we're getting here!). */
    wchar_t **argv_16 = CommandLineToArgvW(GetCommandLineW(), &argc);
    app_init_data.argv = static_cast<char **>(malloc(argc * sizeof(char *)));
    for (int i = 0; i < argc; i++) {
      app_init_data.argv[i] = alloc_utf_8_from_16(argv_16[i], 0);
    }
    LocalFree(argv_16);

    /* Free on early-exit. */
    app_init_data.argv_num = argc;
  }
  const char **argv = const_cast<const char **>(app_init_data.argv);
#  endif /* USE_WIN32_UNICODE_ARGS */
#endif   /* WIN32 */

#if defined(WITH_OPENGL_BACKEND) && BLI_SUBPROCESS_SUPPORT
  if (STREQ(argv[0], "--compilation-subprocess")) {
    BLI_assert(argc == 2);
    GPU_compilation_subprocess_run(argv[1]);
    return 0;
  }
#endif

  /* NOTE: Special exception for guarded allocator type switch:
   *       we need to perform switch from lock-free to fully
   *       guarded allocator before any allocation happened.
   */
  {
    int i;
    for (i = 0; i < argc; i++) {
      if (STR_ELEM(argv[i], "-d", "--debug", "--debug-memory", "--debug-all")) {
        printf("Switching to fully guarded memory allocator.\n");
        MEM_use_guarded_allocator();
        break;
      }
      if (STR_ELEM(argv[i], "--", "-c", "--command")) {
        break;
      }
    }
    MEM_init_memleak_detection();
  }

#ifdef BUILD_DATE
  {
    const time_t temp_time = build_commit_timestamp;
    const tm *tm = gmtime(&temp_time);
    if (LIKELY(tm)) {
      strftime(build_commit_date, sizeof(build_commit_date), "%Y-%m-%d", tm);
      strftime(build_commit_time, sizeof(build_commit_time), "%H:%M", tm);
    }
    else {
      const char *unknown = "date-unknown";
      STRNCPY(build_commit_date, unknown);
      STRNCPY(build_commit_time, unknown);
    }
  }
#endif

  /* Initialize logging. */
  CLG_init();
  CLG_output_use_timestamp_set(true);
  CLG_output_use_memory_set(false);
  CLG_output_use_source_set(false);
  CLG_output_use_basename_set(false);
  CLG_fatal_fn_set(callback_clg_fatal);

  C = CTX_create();

  app_init_data_early_exit.C = C;

#ifdef WITH_PYTHON_MODULE
#  ifdef __APPLE__
  environ = *_NSGetEnviron();
#  endif

#  undef main
  evil_C = C;
#endif

#ifdef WITH_BINRELOC
  br_init(nullptr);
#endif

#ifdef WITH_LIBMV
  libmv_initLogging(argv[0]);
#endif

#if defined(WITH_TBB_MALLOC) && defined(_MSC_VER) && defined(NDEBUG) && defined(WITH_GMP)
  gmp_blender_init_allocator();
#endif

  main_callback_setup();

#if defined(__APPLE__) && !defined(WITH_PYTHON_MODULE) && !defined(WITH_HEADLESS)
  /* Patch to ignore argument finder gives us (PID?). */
  if (argc == 2 && STRPREFIX(argv[1], "-psn_")) {
    static char firstfilebuf[512];

    argc = 1;

    if (GHOST_HACK_getFirstFile(firstfilebuf)) {
      argc = 2;
      argv[1] = firstfilebuf;
    }
  }
#endif

#ifdef __FreeBSD__
  fpsetmask(0);
#endif

  /* Initialize path to executable. */
  BKE_appdir_program_path_init(argv[0]);
#ifdef WITH_APPLE_CROSSPLATFORM
  ios_step("creator: after program_path_init");
  configure_ios_bundle_resource_envvars();
  ios_step("creator: after configure_ios_bundle_resource_envvars");
#endif

  BLI_threadapi_init();
#ifdef WITH_APPLE_CROSSPLATFORM
  ios_step("creator: after BLI_threadapi_init");
#endif

  DNA_sdna_current_init();
#ifdef WITH_APPLE_CROSSPLATFORM
  ios_step("creator: after DNA_sdna_current_init");
#endif

  BKE_blender_globals_init(); /* `blender.cc` */
#ifdef WITH_APPLE_CROSSPLATFORM
  ios_step("creator: after BKE_blender_globals_init");
#endif

  BKE_cpp_types_init();
  BKE_idtype_init();
  BKE_modifier_init();
  blender::seq::modifiers_init();
  BKE_shaderfx_init();
  BKE_volumes_init();
  DEG_register_node_types();

  BKE_callback_global_init();
#ifdef WITH_APPLE_CROSSPLATFORM
  ios_step("creator: after type/id/modifier init");
#endif

/* First test for background-mode (#Global.background). */
#ifndef WITH_PYTHON_MODULE
  ba = BLI_args_create(argc, argv); /* Skip binary path. */

  /* Ensure we free on early exit. */
  app_init_data.ba = ba;

  main_args_setup(C, ba, false);

  /* Parse environment handling arguments. */
  BLI_args_parse(ba, ARG_PASS_ENVIRONMENT, nullptr, nullptr);

#else
  /* Using preferences or user startup makes no sense for #WITH_PYTHON_MODULE. */
  G.factory_startup = true;
#endif

  /* After parsing #ARG_PASS_ENVIRONMENT such as `--env-*`,
   * since they impact `BKE_appdir` behavior. */
  BKE_appdir_init();
#ifdef WITH_APPLE_CROSSPLATFORM
  ios_step("creator: after BKE_appdir_init");
  {
    char assets_path[FILE_MAX] = "";
    const bool found = BKE_appdir_folder_id_ex(
        BLENDER_SYSTEM_DATAFILES, "assets", assets_path, sizeof(assets_path));
    char msg[FILE_MAX + 128];
    SNPRINTF(msg,
             "creator: essentials='%s' is_dir=%d",
             found ? assets_path : "(empty)",
             (found && BLI_is_dir(assets_path)) ? 1 : 0);
    ios_step(msg);
    if (found) {
      char brush_path[FILE_MAX];
      BLI_path_join(brush_path,
                    sizeof(brush_path),
                    assets_path,
                    "brushes",
                    "essentials_brushes-mesh_sculpt.blend");
      SNPRINTF(msg,
               "creator: sculpt_brush_blend exists=%d path='%s'",
               BLI_exists(brush_path) ? 1 : 0,
               brush_path);
      ios_step(msg);
    }
  }
#endif

  /* After parsing number of threads argument. */
  BLI_task_scheduler_init();

  /* Initialize FFTW threading support. */
  blender::fftw::initialize_float();

#ifndef WITH_PYTHON_MODULE
  /* The settings pass includes:
   * - Background-mode assignment (#Global.background), checked by other subsystems
   *   which may be skipped in background mode.
   * - The animation player may be launched which takes over argument passing,
   *   initializes the sub-systems it needs which have not yet been started.
   *   The animation player will call `exit(..)` too, so code after this call
   *   never runs when it's invoked.
   * - All the `--debug-*` flags.
   */
  BLI_args_parse(ba, ARG_PASS_SETTINGS, nullptr, nullptr);

  main_signal_setup();
#endif

  /* Continue with regular initialization, no need to use "early" exit. */
  app_init_data.early_exit = nullptr;

#ifdef WITH_CYCLES
  CCL_log_init();
#endif

  /* Must be initialized after #BKE_appdir_init to account for color-management paths. */
  IMB_init();
  /* Keep after #ARG_PASS_SETTINGS since debug flags are checked. */
  MOV_init();
#ifdef WITH_APPLE_CROSSPLATFORM
  ios_step("creator: after IMB/MOV_init");
#endif

  /* After #ARG_PASS_SETTINGS arguments, this is so #WM_main_playanim skips #RNA_init. */
#ifdef WITH_APPLE_CROSSPLATFORM
  /* True async staging: return to the system main runloop between RNA batches.
   * Nested CFRunLoop yields do not reset the TestFlight launch watchdog. */
  ios_diag("creator: RNA_init begin (async stages)");
  RNA_init_async_begin();
  {
    char buf[96];
    snprintf(buf,
             sizeof(buf),
             "creator: RNA_init total_estimate=%d (chain intact, no prop_lookup_set)",
             RNA_init_async_total_estimate());
    ios_diag(buf);
  }

  g_ios_launch = MEM_new<IosLaunchState>(__func__);
  g_ios_launch->C = C;
#  ifndef WITH_PYTHON_MODULE
  g_ios_launch->ba = ba;
  g_ios_launch->app_init_data.ba = ba;
#  endif
  g_ios_launch->argc = argc;
  g_ios_launch->argv = argv;
  g_ios_launch->app_init_data.early_exit = nullptr;

  BKE_blender_atexit_unregister(callback_main_atexit, &app_init_data);
  BKE_blender_atexit_register(callback_main_atexit, &g_ios_launch->app_init_data);

  GHOST_IOS_schedule_on_main_after(ios_launch_rna_step, g_ios_launch, 0.05);
  ios_diag("creator: returned to system runloop (RNA staged)");
  return 0;
#else
  RNA_init();
#endif

#ifndef WITH_APPLE_CROSSPLATFORM
  RE_texture_rng_init();
  RE_engines_init();
  blender::bke::node_system_init();

  BKE_brush_system_init();
  BKE_particle_init_rng();
  /* End second initialization. */

#if defined(WITH_PYTHON_MODULE) || defined(WITH_HEADLESS)
  /* Python module mode ALWAYS runs in background-mode (for now). */
  G.background = true;
  /* Manually using `--background` also forces the audio device. */
  BKE_sound_force_device("None");
#else
  if (G.background) {
    main_signal_setup_background();
  }
#endif

  /* Background render uses this font too. */
  BKE_vfont_builtin_register(datatoc_bfont_pfb, datatoc_bfont_pfb_size);

  /* Initialize FFMPEG if built in, also needed for background-mode if videos are
   * rendered via FFMPEG. */
  BKE_sound_init_once();

  BKE_materials_init();

#ifndef WITH_PYTHON_MODULE
  if (G.background == 0) {
    BLI_args_parse(ba, ARG_PASS_SETTINGS_GUI, nullptr, nullptr);
  }
  BLI_args_parse(ba, ARG_PASS_SETTINGS_FORCE, nullptr, nullptr);
#endif

  fprintf(stderr, "[ios] before WM_init\n");
  fflush(stderr);
  WM_init(C, argc, argv);
  fprintf(stderr, "[ios] after WM_init\n");
  fflush(stderr);

#ifndef WITH_PYTHON
  printf(
      "\n* WARNING * - Blender compiled without Python!\n"
      "this is not intended for typical usage\n\n");
#endif

#ifdef WITH_FREESTYLE
  /* Initialize Freestyle. */
  FRS_init();
  FRS_set_context(C);
#endif

/* OK we are ready for it. */
#ifndef WITH_PYTHON_MODULE
  /* Handles #ARG_PASS_FINAL. */
  BLI_args_parse(ba, ARG_PASS_FINAL, main_args_handle_load_file, C);
#endif

  /* Explicitly free data allocated for argument parsing:
   * - `ba`
   * - `argv` on WIN32.
   */
  callback_main_atexit(&app_init_data);
  BKE_blender_atexit_unregister(callback_main_atexit, &app_init_data);

/* Paranoid, avoid accidental re-use. */
#ifndef WITH_PYTHON_MODULE
  ba = nullptr;
  (void)ba;
#endif

#ifdef USE_WIN32_UNICODE_ARGS
  argv = nullptr;
  (void)argv;
#endif

#ifndef WITH_PYTHON_MODULE
  if (G.background) {
    int exit_code;
    if (app_state.main_arg_deferred != nullptr) {
      exit_code = main_arg_deferred_handle();
      main_arg_deferred_free();
    }
    else {
      exit_code = G.is_break ? EXIT_FAILURE : EXIT_SUCCESS;
    }
    /* Using window-manager API in background-mode is a bit odd, but works fine. */
    WM_exit(C, exit_code);
  }
  else {
    /* Not supported, although it could be made to work if needed. */
    BLI_assert(app_state.main_arg_deferred == nullptr);

    /* Shows the splash as needed. */
    WM_init_splash_on_startup(C);

    WM_main(C);
  }
  /* Neither #WM_exit, #WM_main return, this quiets CLANG's `unreachable-code-return` warning. */
  BLI_assert_unreachable();

#endif /* !WITH_PYTHON_MODULE */

  return 0;
#endif /* !WITH_APPLE_CROSSPLATFORM */

} /* End of `int main(...)` function. */

#ifdef WITH_PYTHON_MODULE
void main_python_exit()
{
  WM_exit_ex((bContext *)evil_C, true, false);
  evil_C = nullptr;
}
#endif

/** \} */
