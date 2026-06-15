
# only one of the two targets needs this
remove_definitions(-DNO_SOUND)

# Dummy Sound implementation
set(noSoundSources
		IAudioChannel.cpp
		ISound.cpp
		Null/SoundChannels.cpp
		Null/NullSound.cpp
	)

add_library(no-sound STATIC EXCLUDE_FROM_ALL ${noSoundSources})
set_target_properties(no-sound PROPERTIES COMPILE_FLAGS "-DNO_SOUND")
target_link_libraries(no-sound Tracy::TracyClient)

# Define default sound implementation
if    (NO_SOUND)
	set(sound-impl no-sound PARENT_SCOPE)
else  (NO_SOUND)
	set(sound-impl sound PARENT_SCOPE)
endif (NO_SOUND)


# Real Sound implementation
if    (NOT NO_SOUND)
	set(soundSources
			ISound.cpp
			IAudioChannel.cpp
			Null/NullSound.cpp
			OpenAL/ALShared.cpp
			OpenAL/EFX.cpp
			OpenAL/EFXfuncs.cpp
			OpenAL/EFXPresets.cpp
			OpenAL/AudioChannel.cpp
			OpenAL/OggDecoder.cpp
			OpenAL/Mp3Decoder.cpp
			OpenAL/MusicStream.cpp
			OpenAL/Sound.cpp
			OpenAL/SoundChannels.cpp
			OpenAL/SoundBuffer.cpp
			OpenAL/SoundItem.cpp
			OpenAL/SoundSource.cpp
			OpenAL/VorbisShared.cpp
		)

	if    (APPLE)
		# On macOS, find_package(OpenAL) resolves Apple's system
		# OpenAL.framework, whose 3D positional path is broken/deprecated and
		# produces no SFX. Link openal-soft instead. CI installs it with
		# "brew install openal-soft" (a keg-only formula, so it is not in the
		# default link path) and bundles the resulting libopenal.dylib.
		#
		# Locate it via find_library with HINTS rather than a hardcoded path:
		# OPENAL_SOFT_PREFIX (set by CI to "$(brew --prefix openal-soft)") is
		# tried first, followed by the standard Homebrew keg locations on both
		# Apple Silicon and Intel.
		set(OPENAL_SOFT_PREFIX "" CACHE PATH
			"Prefix of an openal-soft installation (e.g. $(brew --prefix openal-soft)). Used on macOS to link openal-soft instead of Apple's OpenAL.framework.")
		find_library(OPENAL_SOFT_LIBRARY
			NAMES openal
			HINTS
				${OPENAL_SOFT_PREFIX}/lib
				/opt/homebrew/opt/openal-soft/lib
				/usr/local/opt/openal-soft/lib
			NO_DEFAULT_PATH
		)
		find_path(OPENAL_SOFT_INCLUDE_DIR
			NAMES al.h
			HINTS
				${OPENAL_SOFT_PREFIX}/include
				/opt/homebrew/opt/openal-soft/include
				/usr/local/opt/openal-soft/include
			PATH_SUFFIXES AL
			NO_DEFAULT_PATH
		)
		if    (NOT OPENAL_SOFT_LIBRARY OR NOT OPENAL_SOFT_INCLUDE_DIR)
			message(FATAL_ERROR "openal-soft not found on macOS. Install it (brew install openal-soft) and pass -DOPENAL_SOFT_PREFIX=$(brew --prefix openal-soft).")
		endif ()
		message(STATUS "macOS: linking openal-soft (${OPENAL_SOFT_LIBRARY}, headers ${OPENAL_SOFT_INCLUDE_DIR})")
		add_library(OpenAL::OpenAL UNKNOWN IMPORTED)
		set_target_properties(OpenAL::OpenAL PROPERTIES
			IMPORTED_LOCATION "${OPENAL_SOFT_LIBRARY}"
			INTERFACE_INCLUDE_DIRECTORIES "${OPENAL_SOFT_INCLUDE_DIR}"
		)
	else  (APPLE)
		find_package_static(OpenAL 1.18.2 REQUIRED)
	endif (APPLE)
	find_package_static(OggVorbis 1.3.4 REQUIRED)

	find_package(SDL2 MODULE REQUIRED)

	include_directories(${CMAKE_SOURCE_DIR}/include/)
	include_directories(${CMAKE_SOURCE_DIR}/include/AL)

	add_library(sound STATIC EXCLUDE_FROM_ALL ${soundSources})
	target_link_libraries(sound SDL2::SDL2)
	target_link_libraries(sound vorbis::vorbisfile vorbis::vorbis Ogg::ogg)
	target_link_libraries(sound OpenAL::OpenAL)
	target_link_libraries(sound Tracy::TracyClient)
endif (NOT NO_SOUND)
