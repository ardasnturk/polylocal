# Polylocal Microphone HAL plug-in. Built by scripts/build-mic-driver.sh; LIBASPL_PREFIX points to an
# installed libASPL (headers + libASPL.a).
cmake_minimum_required(VERSION 3.12.0)
project(PolylocalMicrophone CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(LIBASPL_PREFIX "" CACHE PATH "libASPL install prefix")
set(DRIVER_VERSION "1.0.0" CACHE STRING "Driver version")

add_library(PolylocalMicrophone MODULE Driver.cpp)
target_include_directories(PolylocalMicrophone PRIVATE ${LIBASPL_PREFIX}/include)
target_link_libraries(PolylocalMicrophone PRIVATE ${LIBASPL_PREFIX}/lib/libASPL.a "-framework CoreFoundation")

set_target_properties(PolylocalMicrophone PROPERTIES
  OUTPUT_NAME "PolylocalMicrophone"
  BUNDLE true
  BUNDLE_EXTENSION "driver"
  PREFIX ""
  SUFFIX ""
  MACOSX_BUNDLE ON
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
  MACOSX_BUNDLE_BUNDLE_NAME "PolylocalMicrophone"
  MACOSX_BUNDLE_GUI_IDENTIFIER "dev.polylocal.microphone"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "${DRIVER_VERSION}"
  MACOSX_BUNDLE_BUNDLE_VERSION "${DRIVER_VERSION}"
  MACOSX_BUNDLE_COPYRIGHT "Copyright (c) Polylocal contributors. MIT License."
  )
