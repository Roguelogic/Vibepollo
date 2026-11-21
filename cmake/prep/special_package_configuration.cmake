if(${SUNSHINE_CONFIGURE_HOMEBREW})
    configure_file(packaging/sunshine.rb sunshine.rb @ONLY)
endif()

if(${SUNSHINE_CONFIGURE_PORTFILE})
    configure_file(packaging/macos/Portfile Portfile @ONLY)
endif()

# return if configure only is set
if(${SUNSHINE_CONFIGURE_ONLY})
    message(STATUS "SUNSHINE_CONFIGURE_ONLY: ON, exiting...")
    set(END_BUILD ON)
else()
    set(END_BUILD OFF)
endif()
