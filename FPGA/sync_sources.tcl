# sync_sources.tcl — 同步源码 + 清空缓存 + 重新编译 + 生成 bitstream
# 用法:
#   在 Vivado Tcl Console 中:  cd D:/0_PRJ/Git/data_sampling/FPGA
#                              source sync_sources.tcl
#   或命令行:
#   vivado -mode batch -source sync_sources.tcl

	# 自动检测脚本所在目录，失败则硬编码路径
	if {[info script] ne ""} {
	    set origin_dir [file normalize "[file dirname [info script]]"]
	} else {
	    set origin_dir [pwd]
	}
	if {![file exists "$origin_dir/Artix-7/Artix-7.xpr"]} {
	    set origin_dir "D:/0_PRJ/Git/data_sampling/FPGA"
	}
	set proj_dir   [file normalize "$origin_dir/Artix-7"]
	set src_dir    [file normalize "$origin_dir/srcs/sources_1"]
	puts "  origin_dir = $origin_dir"

# ── 1. 打开项目 ──────────────────────────────────────────
puts "\n========================================"
puts " Step 1: Open Project"
puts "========================================"

# 检查项目是否已打开
set project_already_open [catch {current_project}]
if {$project_already_open} {
    # 项目未打开, 正常打开
    open_project $proj_dir/Artix-7.xpr
    puts "  Project opened: Artix-7"
} else {
    puts "  Project already open: [current_project]"
}

# ── 2. 同步源文件 ────────────────────────────────────────
puts "\n========================================"
puts " Step 2: Sync Source Files"
puts "========================================"

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

	# 先清除旧文件引用，防止残留
	if {[catch {set old_files [get_files -quiet -of_objects [get_filesets sources_1]]}]} {set old_files {}}
	if {[llength $old_files] > 0} {
	    remove_files -quiet $old_files
	    puts "  Removed [llength $old_files] old file refs"
	}
foreach f $source_files {
    set fp [file normalize "$src_dir/$f"]
    if {[file exists $fp]} {
        import_files -force -norecurse -fileset sources_1 $fp
        puts "  OK: $f"
    } else {
        puts "  SKIP (not found): $f"
    }
}

# 固定浮点库 (ieee_proposed)
import_files -force -norecurse -fileset sources_1 \
    [file normalize "$src_dir/fixed_float_pkg/fixed_float_types_c.vhdl"]
import_files -force -norecurse -fileset sources_1 \
    [file normalize "$src_dir/fixed_float_pkg/fixed_pkg_c.vhdl"]

puts "  Done: all sources synced."

# ── 3. 清空之前的综合/实现缓存 ──────────────────────────
puts "\n========================================"
puts " Step 3: Reset & Clean Previous Runs"
puts "========================================"

# 重置综合运行
if {[get_runs -quiet synth_1] != ""} {
    reset_run synth_1
    puts "  synth_1: reset"
}

# 重置实现运行
if {[get_runs -quiet impl_1] != ""} {
    reset_run impl_1
    puts "  impl_1: reset"
}

# 可选: 清理生成文件
# file delete -force [file normalize "$proj_dir/Artix-7.runs"]
# file delete -force [file normalize "$proj_dir/Artix-7.gen"]

puts "  Done: runs reset."

# ── 4. 综合 (Synthesis) ─────────────────────────────────
puts "\n========================================"
puts " Step 4: Run Synthesis"
puts "========================================"

launch_runs synth_1 -jobs 4
wait_on_run synth_1

# 检查综合结果
set syn_status [get_property STATUS [get_runs synth_1]]
puts "  Synthesis status: $syn_status"

if {$syn_status != "synth_design Complete!"} {
    puts "  ERROR: Synthesis failed!"
    puts "  Check log: $proj_dir/Artix-7.runs/synth_1/runme.log"
    exit 1
}

puts "  Synthesis PASSED."

# ── 5. 实现 (Implementation) ─────────────────────────────
puts "\n========================================"
puts " Step 5: Run Implementation"
puts "========================================"

launch_runs impl_1 -jobs 4
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
puts "  Implementation status: $impl_status"

if {$impl_status != "route_design Complete!"} {
    puts "  ERROR: Implementation failed!"
    puts "  Check log: $proj_dir/Artix-7.runs/impl_1/runme.log"
    exit 1
}

puts "  Implementation PASSED."

# ── 6. 生成 Bitstream ────────────────────────────────────
puts "\n========================================"
puts " Step 6: Generate Bitstream"
puts "========================================"

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

set bit_file [file normalize "$proj_dir/Artix-7.runs/impl_1/fpga.bit"]
if {[file exists $bit_file]} {
    set bit_size [file size $bit_file]
    puts "  Bitstream generated: fpga.bit ($bit_size bytes)"
} else {
    puts "  ERROR: Bitstream generation failed!"
    exit 1
}

# ── 7. 时序报告 ──────────────────────────────────────────
puts "\n========================================"
puts " Step 7: Timing & Utilization Reports"
puts "========================================"

open_run impl_1

# 时序摘要
set timing_rpt [file normalize "$proj_dir/Artix-7.runs/impl_1/fpga_timing_summary_routed.rpt"]
if {[file exists $timing_rpt]} {
    set fp [open $timing_rpt r]
    set content [read $fp]
    close $fp
    if {[regexp {Setup\s+:\s+(\d+)\s+Failing Endpoints.*Worst Slack\s+(-?[\d.]+)ns} $content -> failing slack]} {
        puts "  Timing: $failing Failing Endpoints, Worst Slack = $slack ns"
    }
    if {[regexp {Hold\s+:\s+(\d+)\s+Failing Endpoints.*Worst Slack\s+(-?[\d.]+)ns} $content -> failing slack]} {
        puts "  Hold:   $failing Failing Endpoints, Worst Slack = $slack ns"
    }
}

# 利用率
set util_rpt [file normalize "$proj_dir/Artix-7.runs/synth_1/fpga_utilization_synth.rpt"]
puts "  Utilization:"
if {[file exists $util_rpt]} {
    set fp [open $util_rpt r]
    set content [read $fp]
    close $fp
    foreach line [split $content "\n"] {
        if {[regexp {^\|\s*(Slice LUTs|Slice Registers|Block RAM Tile|DSPs)} $line]} {
            puts "    $line"
        }
    }
}

# ── 完成 ─────────────────────────────────────────────────
puts "\n========================================"
puts " BUILD COMPLETE"
puts "========================================"
puts " Bitstream: $bit_file"
puts " Date:      [clock format [clock seconds]]"
puts "========================================\n"
