# rebuild.tcl — 重建Artix-7项目 (仅包含实际存在的源文件)
# 用法: vivado -mode batch -source rebuild.tcl

set origin_dir "D:/0_PRJ/Git/data_sampling/FPGA"
set src_dir    "$origin_dir/srcs/sources_1"

# ── 1. 清理/创建项目 ──────────────────────────
puts "=== Step 1: Create Project ==="
set proj_dir "$origin_dir/Artix-7"

# 清理旧项目 (跳过locked文件)
if {[file exists $proj_dir]} {
    catch {file delete -force "$proj_dir.bak"}
    catch {file rename $proj_dir "$proj_dir.bak"}
    if {[file exists $proj_dir]} {
        puts "  WARNING: Cannot rename old project, creating in new location"
        set proj_dir "$origin_dir/Artix-7_new"
        catch {file delete -force $proj_dir}
    }
}

create_project Artix-7 $proj_dir -part xc7a35tftg256-2 -force
set_property target_language VHDL [current_project]
set_property enable_vhdl_2008 1 [current_project]

# ── 2. 添加源文件 ─────────────────────────────
puts "=== Step 2: Add Source Files ==="
set source_files [list \
    ScopeFun_core.vhd \
    adc_if.vhd \
    RAM_DDR3.vhd \
    ddr3_simple_ui.vhd \
    SPI.vhd \
    blink.vhd \
    clk_divider_wCE.vhd \
    fifo_32_to_128.vhd \
    fifo_128_to_32.vhd \
    fifo_16x20b.vhd \
    mavg.vhd \
    sample_encoder_32_32.vhd \
    timer.vhd \
    SDP_RAM_64x32b.vhd \
    SDP_RAM_32x16b.vhd \
    print_pkg.vhd \
]

foreach f $source_files {
    set fp [file normalize "$src_dir/$f"]
    if {[file exists $fp]} {
        import_files -fileset sources_1 $fp
        puts "  OK: $f"
    } else {
        puts "  MISSING: $f"
    }
}

# 固定浮点库
set fpf "$src_dir/fixed_float_pkg"
import_files -fileset sources_1 "$fpf/fixed_float_types_c.vhdl"
import_files -fileset sources_1 "$fpf/fixed_pkg_c.vhdl"
set_property library ieee_proposed [get_files "*fixed_float_types*"]
set_property library ieee_proposed [get_files "*fixed_pkg_c*"]
puts "  OK: fixed_float_pkg"

# ── 3. IP核 ─────────────────────────────────────
puts "=== Step 3: Add IP Cores ==="
import_ip "$src_dir/ip/clk_wiz_0/clk_wiz_0.xci"
import_ip "$src_dir/ip/mig_ddr3/mig_ddr3.xci"
import_ip "$src_dir/ip/fifo_gen_0/fifo_gen_0.xci"
puts "  OK: IP cores added"

# 设顶层
set_property top fpga [get_filesets sources_1]

# ── 4. 约束文件 ─────────────────────────────────
puts "=== Step 4: Add Constraints ==="
add_files -fileset constrs_1 "$origin_dir/srcs/constrs_1/io_loc.xdc"
add_files -fileset constrs_1 "$origin_dir/srcs/constrs_1/timing.xdc"
add_files -fileset constrs_1 "$origin_dir/srcs/constrs_1/bitstream.xdc"

# ── 5. 综合 ─────────────────────────────────────
	# ── 4.5 综合/实现策略 (同原项目) ────────────────
	puts "=== Step 4.5: Apply Strategies ==="
	set_property strategy "Flow_PerfOptimized_high" [get_runs synth_1]
	set_property steps.synth_design.args.directive "PerformanceOptimized" [get_runs synth_1]
	set_property steps.synth_design.args.fsm_extraction "one_hot" [get_runs synth_1]
	set_property steps.synth_design.args.keep_equivalent_registers 1 [get_runs synth_1]
	set_property steps.synth_design.args.resource_sharing "off" [get_runs synth_1]
	set_property steps.synth_design.args.no_lc 1 [get_runs synth_1]
	set_property steps.synth_design.args.shreg_min_size 5 [get_runs synth_1]
	set_property strategy "Performance_RefinePlacement" [get_runs impl_1]
	set_property steps.place_design.args.directive "ExtraPostPlacementOpt" [get_runs impl_1]
	set_property steps.phys_opt_design.args.directive "Explore" [get_runs impl_1]
	set_property steps.route_design.args.directive "Explore" [get_runs impl_1]
	puts "  Strategies applied"
puts "=== Step 5: Run Synthesis ==="
launch_runs synth_1 -jobs 8
wait_on_run synth_1

set syn_status [get_property STATUS [get_runs synth_1]]
puts "  Synthesis: $syn_status"
if {$syn_status ne "synth_design Complete!"} {
    puts "  SYNTHESIS FAILED!"
    exit 1
}

# ── 6. 实现 ─────────────────────────────────────
puts "=== Step 6: Run Implementation ==="
launch_runs impl_1 -jobs 8
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
puts "  Implementation: $impl_status"
if {$impl_status ni {"route_design Complete!" "route_design Complete, Failed Timing!"}} {
    puts "  IMPLEMENTATION FAILED!"
    exit 1
}

# ── 7. Bitstream ────────────────────────────────
	puts "=== Step 7: Generate Bitstream ==="
	# 启用 .bin 文件生成
	set_property steps.write_bitstream.args.bin_file 1 [get_runs impl_1]
	launch_runs impl_1 -to_step write_bitstream -jobs 8
	wait_on_run impl_1

	# ── 8. 复制 .bin 到 host firmware 目录 ──────────
	puts "=== Step 8: Copy to Host Firmware ==="
	set bin_src [file normalize "$proj_dir/Artix-7.runs/impl_1/fpga.bin"]
	set firmware_dir [file normalize "D:/0_PRJ/Git/data_sampling_PC_host/bin/data/firmware"]
	if {[file exists $bin_src]} {
	    file mkdir $firmware_dir
	    file copy -force $bin_src "$firmware_dir/fpga2.bin"
	    puts "  Copied: $bin_src → $firmware_dir/fpga2.bin"
	} else {
	    puts "  WARNING: .bin not found at $bin_src"
	}

	puts "
=== DONE ==="
	puts "Bitstream: [file normalize $proj_dir/Artix-7.runs/impl_1/fpga.bit]"
