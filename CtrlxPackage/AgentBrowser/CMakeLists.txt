cmake_minimum_required(VERSION 3.21)
project(CtrlXAgentBrowser LANGUAGES C CXX OBJCXX)

if(NOT APPLE OR NOT CEF_ROOT)
  message(FATAL_ERROR "Use scripts/build-agent-browser.sh on macOS.")
endif()
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD 20)
set(PROJECT_ARCH arm64)
set(USE_SANDBOX ON CACHE BOOL "Keep Chromium's sandbox enabled" FORCE)
list(APPEND CMAKE_MODULE_PATH "${CEF_ROOT}/cmake")
find_package(CEF REQUIRED)
add_subdirectory("${CEF_LIBCEF_DLL_WRAPPER_PATH}" libcef_dll_wrapper)

function(probe_target target source name identifier)
  add_executable(${target} MACOSX_BUNDLE ${source})
  SET_EXECUTABLE_TARGET_PROPERTIES(${target})
  target_include_directories(${target} PRIVATE "${CEF_ROOT}")
  target_link_libraries(${target} PRIVATE libcef_dll_wrapper ${CEF_STANDARD_LIBS})
  set_target_properties(${target} PROPERTIES
    OUTPUT_NAME "${name}"
    MACOSX_BUNDLE_GUI_IDENTIFIER "${identifier}"
    MACOSX_BUNDLE_BUNDLE_NAME "${name}"
    MACOSX_BUNDLE_BUNDLE_VERSION "1"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "0.1"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in")
endfunction()

add_library(browser_runtime SHARED EmbeddedBrowser.mm AutomationBridge.mm)
target_include_directories(browser_runtime PRIVATE "${CEF_ROOT}")
target_link_libraries(browser_runtime PRIVATE libcef_dll_wrapper ${CEF_STANDARD_LIBS} "-framework ImageIO" "-framework CoreGraphics")
target_compile_options(browser_runtime PRIVATE -fobjc-arc)
set_target_properties(browser_runtime PROPERTIES OUTPUT_NAME CtrlXAgentBrowser
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/Embedded/Frameworks")
add_executable(remote_browser_frame_tests EXCLUDE_FROM_ALL tests/remote_browser_frame.mm)
target_compile_options(remote_browser_frame_tests PRIVATE -fobjc-arc -UNDEBUG)
target_link_libraries(remote_browser_frame_tests PRIVATE "-framework Foundation" "-framework ImageIO" "-framework CoreGraphics")
# The SDK ships a flat framework; macOS applications need CEF's versioned
# layout, including Versions/Current and resource/library symlinks.
set(PROBE_FRAMEWORK "${CMAKE_BINARY_DIR}/Embedded/Frameworks/Chromium Embedded Framework.framework")
add_custom_command(TARGET browser_runtime POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_directory
    "${CEF_ROOT}/Release/Chromium Embedded Framework.framework" "${PROBE_FRAMEWORK}/Versions/A"
  # -h replaces the link itself on repeated builds, never follows a directory
  # symlink and creates a broken nested link inside the framework resources.
  COMMAND /bin/ln -sfh "Versions/A/Chromium Embedded Framework" "${PROBE_FRAMEWORK}/Chromium Embedded Framework"
  COMMAND /bin/ln -sfh "Versions/A/Libraries" "${PROBE_FRAMEWORK}/Libraries"
  COMMAND /bin/ln -sfh "Versions/A/Resources" "${PROBE_FRAMEWORK}/Resources"
  COMMAND /bin/ln -sfh A "${PROBE_FRAMEWORK}/Versions/Current"
  VERBATIM)
add_custom_command(TARGET browser_runtime POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_BINARY_DIR}/Embedded/Resources"
  COMMAND ${CMAKE_COMMAND} -E copy "${CEF_ROOT}/LICENSE.txt"
    "${CMAKE_BINARY_DIR}/Embedded/Resources/CEF-LICENSE.txt"
  COMMAND ${CMAKE_COMMAND} -E copy "${CEF_ROOT}/CREDITS.html"
    "${CMAKE_BINARY_DIR}/Embedded/Resources/CEF-CREDITS.html"
  VERBATIM)

foreach(suffix IN LISTS CEF_HELPER_APP_SUFFIXES)
  string(REPLACE ":" ";" parts "${suffix}")
  list(GET parts 0 app_suffix)
  list(GET parts 1 target_suffix)
  list(GET parts 2 id_suffix)
  set(helper "probe_helper${target_suffix}")
  probe_target(${helper} Helper.cc "CtrlX Agent Browser Helper${app_suffix}"
    "com.ctrlx.agent-browser.helper${id_suffix}")
  set_target_properties(${helper} PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/Embedded/Frameworks")
  add_custom_command(TARGET ${helper} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_BUNDLE_DIR:${helper}>/Contents/Resources"
    VERBATIM)
  add_dependencies(browser_runtime ${helper})
endforeach()
