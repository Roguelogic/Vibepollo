# Publisher Metadata
set(SUNSHINE_PUBLISHER_NAME "Roguelogic"
        CACHE STRING "The name of the publisher (not developer) of the application.")
set(SUNSHINE_PUBLISHER_WEBSITE "https://github.com/Roguelogic/Vibepollo"
        CACHE STRING "The URL of the publisher's website.")
set(SUNSHINE_PUBLISHER_ISSUE_URL "https://github.com/Roguelogic/Vibepollo/issues"
        CACHE STRING "The URL of the publisher's support site or issue tracker.")

option(BUILD_TESTS "Build unit tests." OFF)
option(BUILD_WERROR "Enable -Werror flag." OFF)

# if this option is set, the build will exit after configuring special package configuration files
option(SUNSHINE_CONFIGURE_ONLY "Configure special files only, then exit." OFF)

option(SUNSHINE_ENABLE_TRAY "Enable system tray icon." ON)
option(SUNSHINE_ENABLE_PYROWAVE "Enable the PyroWave video codec." OFF)
option(BOOST_USE_STATIC "Use static boost libraries." OFF)

option(SUNSHINE_BUILD_HOMEBREW "Enable a Homebrew build." OFF)
option(SUNSHINE_CONFIGURE_HOMEBREW "Configure Homebrew formula. Recommended to use with SUNSHINE_CONFIGURE_ONLY" OFF)
option(SUNSHINE_CONFIGURE_PORTFILE "Configure macOS Portfile. Recommended to use with SUNSHINE_CONFIGURE_ONLY" OFF)
