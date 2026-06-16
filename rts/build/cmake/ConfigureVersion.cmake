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

# Reported-version resolution for the macOS layer branches.
# The macOS layer sits past the base release tag, so the default git-describe
# (fetch_spring_version above) yields a development string "<tag>-N-g<sha>". The
# engine must report the base release version (e.g. 2026.06.08) to match the
# autohosts. Derive it branch-agnostically from the nearest release tag: the glob
# "[0-9]*" matches release tags and excludes the engine-macos-arm64-* release
# tags, and --abbrev=0 strips the "-N-g<sha>" suffix. An explicit PINNED_VERSION
# file at the source root still overrides, so a branch may pin a different value.
set(_spring_version_pinned FALSE)
if    (EXISTS "${SOURCE_ROOT}/PINNED_VERSION")
	get_version_from_file(SPRING_ENGINE_PINNED "${SOURCE_ROOT}/PINNED_VERSION")
	if    (NOT SPRING_ENGINE_PINNED-NOTFOUND)
		message(STATUS "Engine version pinned via PINNED_VERSION file: ${SPRING_ENGINE_PINNED} (overriding git-describe \"${SPRING_ENGINE_VERSION}\")")
		set(SPRING_ENGINE_VERSION "${SPRING_ENGINE_PINNED}")
		set(_spring_version_pinned TRUE)
	endif ()
endif ()
if    (NOT _spring_version_pinned)
	git_util_describe(SPRING_ENGINE_NEAREST_TAG "${SOURCE_ROOT}" "[0-9]*" --abbrev=0)
	if    (SPRING_ENGINE_NEAREST_TAG)
		message(STATUS "Engine version auto-derived from nearest release tag: ${SPRING_ENGINE_NEAREST_TAG} (git-describe was \"${SPRING_ENGINE_VERSION}\")")
		set(SPRING_ENGINE_VERSION "${SPRING_ENGINE_NEAREST_TAG}")
	endif ()
endif ()
unset(_spring_version_pinned)

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
