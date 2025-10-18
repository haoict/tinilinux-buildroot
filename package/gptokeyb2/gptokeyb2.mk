################################################################################
#
# GPTOKEYB2
#
################################################################################

GPTOKEYB2_VERSION = 70318903a96d934736a2239da581d04dbb4a66e4
GPTOKEYB2_SITE = https://github.com/PortsMaster/gptokeyb2.git
GPTOKEYB2_SITE_METHOD = git
GPTOKEYB2_DEPENDENCIES = host-pkgconf libevdev sdl2
GPTOKEYB2_CONF_OPTS = -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS="-U_FILE_OFFSET_BITS"
GPTOKEYB2_INSTALL_TARGET = YES

define GPTOKEYB2_INSTALL_TARGET_CMDS
    mkdir -p $(TARGET_DIR)/usr/local/bin
    $(INSTALL) -D -m 0755 $(@D)/gptokeyb2  $(TARGET_DIR)/usr/local/bin/
endef

$(eval $(cmake-package))
