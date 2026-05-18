###############################################################################
#    Copyright (C) 2016-2023 Dejan Priversek
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the-
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
###############################################################################

# ====================================================================
# 1. Primary Clock — 仅此一个，定义在顶层物理端口上
# ====================================================================
# ADC 采样时钟为 250 MHz。
# 注：PCB 上 LVDS 差分对正负端接反（DCO+ 在 N-pad、DCO- 在 P-pad），
# IBUFDS 硅片硬连线为 O = P-pad - N-pad，输出始终反相。
# 此处用 180° 相位的 waveform 匹配 IBUFDS 输出的反相时钟。
create_clock -period 4.000 -name clk_adc_p -waveform {2.000 4.000} [get_ports clk_adc_p]
# 允许该时钟走专用时钟骨干网络。
set_property CLOCK_DEDICATED_ROUTE BACKBONE [get_nets clk_adc_p]
# 输入时钟抖动，单位是 ns。
set_input_jitter clk_adc_p 0.012

# ====================================================================
# 2. PLL输出时钟 — 由Vivado自动推导
#    clk_wiz_0 PLL 输出 (clk_ref_i, clk_gen) 由 Vivado 自动追踪推导。
#    adc_if 内的 NOT(i_clk_buff) 将 IBUFDS 反相输出修正为正常极性，
#    因此 clk_adc_dclk 波形正常。
# ====================================================================

# ====================================================================
# 3. Asynchronous Clock Groups
#    ADC采样域 (clk_adc_p) 与 MIG/DDR3 域 (ui_clk) 经不同 PLL,
#    无确定性相位关系，通过异步 FIFO + 同步器跨域。
# ====================================================================
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks clk_adc_p] \
    -group [get_clocks -of_objects [get_pins RAM_DDR3_inst/RAM/u_mig_ddr3/ui_clk]]

# calib_done 到 ADC 接口旧 FIFO 使能路径已移除（adc_if 中已无 data_fifo_16x20b 实例）。
# 读取校准启动脉冲到 ADC 接口内部寄存器。
set_max_delay -datapath_only -from [get_pins read_calib_start_reg/C] -to [get_pins ADC_interface/read_calib_start_reg/D] 2.000
# 校准源选择信号到 ADC 接口内部寄存器。
set_max_delay -datapath_only -from [get_pins read_calib_source_reg/C] -to [get_pins ADC_interface/read_calib_source_reg/D] 2.000

# clearflags 是异步清状态信号，不按普通时序路径分析。
set_false_path -from [get_pins clearflags*/C] -to [get_pins RAM_DDR3_inst/RAM_WRITE_FIFO/reset_reg/D]
set_false_path -from [get_pins clearflags*/C] -to [get_pins RAM_DDR3_inst/RAM_WRITE_FIFO/rst_d_reg/D]

# 分布式 RAM 采用先写后读的使用方式，读路径允许适度放宽。
set_max_delay -datapath_only -from [get_pins config_RAM/RAM_reg_0_63_*/DP/CLK] -to [get_pins {config_RAM/do2_reg[*]/D}] 2.000

# clk_adc 域到 clk_fx3 域的控制/状态同步路径。
set_max_delay -datapath_only -from [get_cells {timebase_d_reg[*]}] -to [get_cells {timebase_dd_reg[*]}] 2.000
set_max_delay -datapath_only -from [get_pins triggered_reg/C] -to [get_pins triggered_d_reg/D] 2.000
set_max_delay -datapath_only -from [get_pins {framesize_d_reg[*]/C}] -to [get_pins {framesize_dd_reg[*]/D}] 2.000
set_max_delay -datapath_only -from [get_pins getnewframe_reg/C] -to [get_pins getnewframe_d_reg/D] 2.000
set_max_delay -datapath_only -from [get_pins {RAM_DDR3_inst/PreTrigSavingCnt_reg[*]/C}] -to [get_pins {RAM_DDR3_inst/PreTrigSavingCnt_d_reg[*]/D}] 2.000
set_max_delay -datapath_only -from [get_pins clearflags*/C] -to [get_pins RAM_DDR3_inst/rst_d_reg/D] 2.000
set_max_delay -datapath_only -from [get_pins {encoding_format_d_reg[*]/C}] -to [get_pins {encoding_format_dd_reg[*]/D}] 2.000

# clk_fx3 域到 clk_adc 域的控制/状态同步路径。
set_max_delay -datapath_only -from [get_pins clearflags_reg/C] -to [get_pins clearflags_d_reg/D] 2.000
set_max_delay -datapath_only -from [get_pins requestFrame_reg/C] -to [get_pins requestFrame_d_reg/D] 2.000
set_max_delay -datapath_only -from [get_pins RAM_DDR3_inst/PreTrigSavingCntRecvd_reg/C] -to [get_pins RAM_DDR3_inst/PreTrigSavingCntRecvd_d_reg/D] 2.000
set_max_delay -datapath_only -from [get_pins RAM_DDR3_inst/ram_rdy_i_reg/C] -to [get_pins RAM_DDR3_inst/ram_rdy_reg/D] 2.000
set_max_delay -datapath_only -from [get_pins {pre_trigger_d_reg[*]/C}] -to [get_pins {RAM_DDR3_inst/RAM/wr_pretriglen_reg[*]/D}] 2.000
set_max_delay -datapath_only -from [get_pins ScopeConfigChanged_reg/C] -to [get_pins ScopeConfigChanged_d_reg/D] 2.000
set_max_delay -datapath_only -from [get_pins reading_config_registers_reg/C] -to [get_pins reading_config_registers_d_reg/D] 2.000

# DDR3 控制器：写 FIFO 复位、满标志和控制路径。
set_max_delay -datapath_only -from [get_pins RAM_DDR3_inst/RAM_WRITE_FIFO/FIFO_DUALCLOCK_MACRO_inst1/bl.fifo_36_inst_bl_1.fifo_36_bl_1/WRCLK] -to [get_pins RAM_DDR3_inst/fwr_AlmostFull_d_reg/D] 2.000
set_false_path -from [get_pins RAM_DDR3_inst/RAM_WRITE_FIFO/rst_i_reg/C] -to [get_pins RAM_DDR3_inst/RAM_WRITE_FIFO/FIFO_DUALCLOCK_MACRO_inst1/bl.fifo_36_inst_bl_1.fifo_36_bl_1/RST]
set_false_path -from [get_pins RAM_DDR3_inst/RAM_WRITE_FIFO/rst_i_reg/C] -to [get_pins RAM_DDR3_inst/RAM_WRITE_FIFO/FIFO_DUALCLOCK_MACRO_inst2/bl.fifo_36_inst_bl_1.fifo_36_bl_1/RST]
set_false_path -from [get_pins RAM_DDR3_inst/RAM_WRITE_FIFO/reset_reg/C] -to [get_pins RAM_DDR3_inst/RAM_WRITE_FIFO/FIFO_DUALCLOCK_MACRO_inst1/bl.fifo_36_inst_bl_1.fifo_36_bl_1/RDEN]
set_false_path -from [get_pins RAM_DDR3_inst/RAM_WRITE_FIFO/reset_reg/C] -to [get_pins RAM_DDR3_inst/RAM_WRITE_FIFO/FIFO_DUALCLOCK_MACRO_inst2/bl.fifo_36_inst_bl_1.fifo_36_bl_1/RDEN]

# 旧版 dataA_p/dataB_p 外部输入延迟约束已移除。
# 当前顶层端口已改为 data_p/data_n，ADC 采样窗口由 adc_if 内部 IDELAY/IDDR 校准处理。


# 仅放宽调试状态信号的跨域同步路径。
set_max_delay -datapath_only -from [get_pins {DebugADCState_reg[*]/C}] -to [get_pins {DebugADCState_d_reg[*]/D}] 4.000
