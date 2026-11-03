FILES=configs/naxriscv_sim_raw_defconfig \
      boards/naxriscv_sim/linux/linux_raw.config\
      boards/naxriscv_sim/linux/linux_raw.dts \
      boards/naxriscv_sim/opensbi/config_raw.mk

# NaxMiniSoC（本工程）板变体的四个模板 —— 用 naxmini_setup.sh 生成非 raw 版本
FILES+=configs/naxmini_raw_defconfig \
      boards/naxmini/linux/linux_raw.config\
      boards/naxmini/linux/linux_raw.dts \
      boards/naxmini/opensbi/config_raw.mk


%: %_raw
	cpp -E -P $^ > $@

rawrrr : $(FILES)
	echo $(FILES)
