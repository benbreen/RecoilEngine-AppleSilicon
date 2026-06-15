# This file is part of the Spring engine (GPL v2 or later), see LICENSE.html

#
# example usage:
#Add_Custom_Command(
#	TARGET
#		configureVersion
#	COMMAND "${CMAKE_COMMAND}"
#		"-DSOURCE_ROOT=${CMAKE_SOURCE_DIR}"
#		"-DCMAKE_MODULES_SPRING=${CMAKE_MODULES_SPRING}"
#		"-DVERSION_ADDITIONAL=ABC"
#		"-DGENERATE_DIR=${CMAKE_BINARY_DIR}"
#		"-P" "${CMAKE_MODULES_SPRING}/ConfigureFile.cmake"
#	COMMENT
#		"Configure Version files" VERBATIM
#	)
#

cmake_minimum_required(VERSION 3.27)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_MODULES_SPRING}")

include(UtilVersion)



# Fetch through git or from the VERSION file
fetch_spring_version(${SOURCE_ROOT} SPRING_ENGINE)

# Version pin override.
# This branch is the 2026.06.08 release tag plus a set of sim-neutral macOS
# platform commits (rendering, threading stubs, CMake, AppleClang shims). Because
# HEAD sits past the tag, git-describe yields a development string such as
# "2026.06.08-27-g<sha> <branch>", which would make the engine report a dev
# version. The simulation is unchanged from 2026.06.08, so the reported engine
# version must remain exactly that tag. If a PINNED_VERSION file exists at the
# source root and contains a valid release version, it takes precedence over the
# git-describe result.
if    (EXISTS "${SOURCE_ROOT}/PINNED_VERSION")
	get_version_from_file(SPRING_ENGINE_PINNED "${SOURCE_ROOT}/PINNED_VERSION")
	if    (NOT SPRING_ENGINE_PINNED-NOTFOUND)
		message(STATUS "Engine version pinned via PINNED_VERSION file: ${SPRING_ENGINE_PINNED} (overriding git-describe \"${SPRING_ENGINE_VERSION}\")")
		set(SPRING_ENGINE_VERSION "${SPRING_ENGINE_PINNED}")
	endif ()
endif ()

parse_spring_version(SPRING_VERSION_ENGINE "${SPRING_ENGINE_VERSION}")

# We define these, so it may be used in the to-be-configured files
set(SPRING_VERSION_ENGINE "${SPRING_ENGINE_VERSION}")
if     ("${SPRING_VERSION_ENGINE}" MATCHES "^${VERSION_REGEX_RELEASE}$")
	set(SPRING_VERSION_ENGINE_RELEASE 1)
else   ()
	set(SPRING_VERSION_ENGINE_RELEASE 0)
endif  ()

# This is supplied by -DVERSION_ADDITIONAL="abc"
set(SPRING_VERSION_ENGINE_ADDITIONAL "${VERSION_ADDITIONAL}")



message("Spring engine version: ${SPRING_ENGINE_VERSION} (${SPRING_VERSION_ENGINE_ADDITIONAL})")



file(MAKE_DIRECTORY "${GENERATE_DIR}/src-generated/engine/System")
configure_file(
		"${SOURCE_ROOT}/rts/System/VersionGenerated.h.template"
		"${GENERATE_DIR}/src-generated/engine/System/VersionGenerated.h"
		@ONLY
	)

file(MAKE_DIRECTORY "${GENERATE_DIR}")
configure_file(
		"${SOURCE_ROOT}/VERSION.template"
		"${GENERATE_DIR}/VERSION"
		@ONLY
	)
