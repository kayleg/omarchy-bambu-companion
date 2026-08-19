cmake_minimum_required(VERSION 3.16)
project(bambu_toolpath LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

find_package(Qt6 REQUIRED COMPONENTS Quick ShaderTools)
qt_policy(SET QTP0001 NEW)

qt_add_qml_module(bambutoolpathplugin
  URI Bambu.Toolpath
  VERSION 1.0
  PLUGIN_TARGET bambutoolpathplugin
  OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/qml/Bambu/Toolpath
  SOURCES gcode_route.hpp gcode_route.cpp
  QML_FILES RouteHost.qml
  NO_GENERATE_EXTRA_QMLDIRS
  NO_PLUGIN_OPTIONAL
)

target_link_libraries(bambutoolpathplugin PRIVATE Qt6::Quick)

qt_add_shaders(bambutoolpathplugin "route_shaders"
  BATCHABLE
  PRECOMPILE
  OPTIMIZED
  PREFIX "/io/github/ypmrg/bambu"
  FILES gcode_route.vert gcode_route.frag
)

install(DIRECTORY ${CMAKE_BINARY_DIR}/qml/Bambu/Toolpath/
        DESTINATION .
        FILES_MATCHING PATTERN "*"
        PATTERN "*.a" EXCLUDE)
