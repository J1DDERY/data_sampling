#!/usr/bin/env python3
"""
Transform original ScopeFun_core.vhd → adapted version:
- Remove: AWG, LA, PWM, digital channels, analog trigger, ETS, CORDIC,
  digital POT, second ADC, I-DAC, ADC interleaving, lut_delay
- Adapt: 14-bit AD9643 ADC (single dual-channel chip)
- Keep: original clock scheme, state machine structure, flow control
"""

import re

SRC = "D:/0_PRJ/Git/scopefun_original/scopefun-firmware-master/FPGA/srcs/sources_1/ScopeFun_core.vhd"
DST = "D:/0_PRJ/Git/data_sampling/FPGA/srcs/sources_1/ScopeFun_core_origbased.vhd"

with open(SRC, "r", encoding="utf-8", errors="replace") as f:
    lines = f.readlines()

print(f"Read {len(lines)} lines from original")

# ── New entity port block ──
NEW_PORTS = """	Port (
		-- FX3 interface
		fdata         : inout STD_LOGIC_VECTOR(31 downto 0);	-- FIFO data lines.
		faddr         : out STD_LOGIC_VECTOR(1 downto 0);		-- FIFO select lines
		slcs          : out STD_LOGIC;                          -- Slave select control line
		slwr          : out STD_LOGIC;                          -- Write control line (asserted_low)
		slrd_sloe     : out STD_LOGIC;                          -- Read control line (SLOE & SLRD are tied together)
		LED           : out STD_LOGIC_VECTOR(3 downto 1);       -- LED indicators
		flaga         : in STD_LOGIC;                           -- EP2 - OUT Empty flag (all flags acive low)
		flagb         : in STD_LOGIC;                           -- EP4 - OUT Empty flag
		pktend        : out STD_LOGIC;                          -- Commit short packet (asserted_low)
		flagd         : in STD_LOGIC;                           -- EP6 - IN Full Flag
		clk_fx3       : out STD_LOGIC;                          -- FX3 GPIF Clock
		-- ADC interface (AD9643: 14-bit dual-channel)
		clk_adc_p     : in STD_LOGIC;           -- ADC clock LVDS p
		clk_adc_n     : in STD_LOGIC;
		data_p       : in std_logic_vector(13 downto 0);  -- ADC data (LVDS DDR)
		data_n       : in std_logic_vector(13 downto 0);  -- ADC data
		adc_sclk      : out STD_LOGIC;        -- ADC serial-interface clock
		adc_sdin      : out STD_LOGIC;        -- ADC serial-interface data
		adcA_cs		  : out STD_LOGIC;        -- ADC serial-interface cs#
		-- DAC interface (control DAC only)
		dasync        : out STD_LOGIC;		-- V-DAC serial-interface update signal
		dasclk        : out STD_LOGIC;		-- V-DAC serial-interface clock
		dasdin        : out STD_LOGIC;		-- V-DAC serial-interface data
		-- Analog switching
		ch1_dc	      : out STD_LOGIC;    -- DC/AC switch
		ch2_dc	      : out STD_LOGIC;
		ch1_gnd       : out STD_LOGIC;    -- GND switch
		ch2_gnd       : out STD_LOGIC;
		ch1_k         : out STD_LOGIC;    -- attenuator switch
		ch2_k         : out STD_LOGIC;
		-- DDR3
		ddr3_dq      : inout std_logic_vector(15 downto 0);
		ddr3_dqs_p   : inout std_logic_vector(1 downto 0);
		ddr3_dqs_n   : inout std_logic_vector(1 downto 0);
		ddr3_addr    : out std_logic_vector(14 downto 0);
		ddr3_ba      : out std_logic_vector(2 downto 0);
		ddr3_ras_n   : out std_logic;
		ddr3_cas_n   : out std_logic;
		ddr3_we_n    : out std_logic;
		ddr3_reset_n : out std_logic;
		ddr3_ck_p    : out std_logic_vector(0 downto 0);
		ddr3_ck_n    : out std_logic_vector(0 downto 0);
		ddr3_cke     : out std_logic_vector(0 downto 0);
		ddr3_odt     : out std_logic_vector(0 downto 0)
	);"""

# ── New ADC component declaration ──
NEW_ADC_COMPONENT = """	component adc_if is
		generic (
			ADC_BITS : integer := 14
		);
		Port (
			i_clk_p : in STD_LOGIC;
			i_clk_n : in STD_LOGIC;
			i_clk_ref : in std_logic;
			i_reset_n : in std_logic;
			i_en_fifo : in std_logic;
			i_read_calib_start : in std_logic;
			i_read_calib_source : in std_logic;
			i_data_p : in STD_LOGIC_VECTOR (ADC_BITS-1 downto 0);
			i_data_n : in STD_LOGIC_VECTOR (ADC_BITS-1 downto 0);
			o_clk : out STD_LOGIC;
			o_data_1 : out STD_LOGIC_VECTOR (ADC_BITS-1 downto 0);
			o_data_2 : out STD_LOGIC_VECTOR (ADC_BITS-1 downto 0)
		);
	end component;
"""

# ── New SPI component with 24-bit generic ──
NEW_SPI_COMPONENT = """	component spi is
		generic (
			SPI_LENGTH : integer -- NUMBER OF BITS TRANSFERED
		);
		Port ( clk : in  std_logic;
			   rst : in std_logic;
			   clk_divide : in std_logic_vector (4 downto 0);
			   spi_data : in  std_logic_vector (SPI_LENGTH-1 downto 0);
			   spi_write_trig : in std_logic;
			   sck_idle_value : in std_logic;
			   spi_busy : out std_logic;
			   cs : out  std_logic;
			   sck : out  std_logic;
			   si : out  std_logic
		);
	end component;
"""

# ── Find line ranges to remove ──

def find_block(lines, start_pattern, end_pattern, start_idx=0):
    """Find a block from start_pattern to end_pattern (inclusive line indices)"""
    for i in range(start_idx, len(lines)):
        if re.search(start_pattern, lines[i]):
            for j in range(i, len(lines)):
                if re.search(end_pattern, lines[j]):
                    return (i, j)
    return None

def find_component_range(lines, comp_name):
    """Find component declaration range"""
    for i, line in enumerate(lines):
        if re.search(rf"component\s+{comp_name}\b", line, re.IGNORECASE):
            # Find end component
            for j in range(i, len(lines)):
                if re.search(r"end\s+component", lines[j], re.IGNORECASE):
                    return (i, j)
    return None

def find_signal_lines(lines, pattern):
    """Find all line indices matching a signal declaration pattern"""
    result = []
    for i, line in enumerate(lines):
        if re.search(pattern, line) and 'signal' in line.lower():
            result.append(i)
    return result

# ── Build list of lines to remove ──
remove_lines = set()

# 1. Entity port block: remove old, insert new later
port_range = find_block(lines, r"Port\s*\(", r"^\s*\);", 0)
if port_range:
    for i in range(port_range[0], port_range[1] + 1):
        remove_lines.add(i)
    entity_port_start = port_range[0]
else:
    entity_port_start = None

# 2. Component declarations to remove
comps_to_remove = [
    "awg_core", "LA_core", "dig_pattern_gen", "lut_delay",
    "pwm", "se_to_ddr", "clk_gen_pll", "SDP_BRAM_custom_signal",
    "rand_gen", "cordic_par", "angle_gen"
]
for comp in comps_to_remove:
    r = find_component_range(lines, comp)
    if r:
        for i in range(r[0], r[1] + 1):
            remove_lines.add(i)
        print(f"  Removing component: {comp} (lines {r[0]+1}-{r[1]+1})")

# 3. Find old ADC component declaration to replace
adc_comp_range = find_component_range(lines, "adc_if")
if adc_comp_range:
    for i in range(adc_comp_range[0], adc_comp_range[1] + 1):
        remove_lines.add(i)
    adc_comp_pos = adc_comp_range[0]
    print(f"  Replacing ADC component (lines {adc_comp_range[0]+1}-{adc_comp_range[1]+1})")
else:
    adc_comp_pos = None

# 4. Find old SPI component to replace
spi_comp_range = find_component_range(lines, "spi")
if spi_comp_range:
    for i in range(spi_comp_range[0], spi_comp_range[1] + 1):
        remove_lines.add(i)
    spi_comp_pos = spi_comp_range[0]
    print(f"  Replacing SPI component (lines {spi_comp_range[0]+1}-{spi_comp_range[1]+1})")
else:
    spi_comp_pos = None

# 5. Signal declarations to remove
sig_patterns_to_remove = [
    # AWG signals
    r"signal\s+dac_data_[12]", r"signal\s+dac_clk\b",
    r"signal\s+wea_awg", r"signal\s+addra_awg", r"signal\s+dina_awg",
    r"signal\s+addrb_awg", r"signal\s+doutb_awg",
    r"signal\s+awg[12]_phase_trig",
    # Digital I/O
    r"signal\s+dataD_d", r"signal\s+dataD_in\b",
    # Digital pattern
    r"signal\s+digitalPattern",
    r"signal\s+rand_bit",
    # Analog trigger / ETS
    r"signal\s+an_trig_d\b", r"signal\s+an_trig_dd\b",
    r"signal\s+an_trig_ddd\b", r"signal\s+an_trig_dddd\b",
    r"signal\s+an_trig_delay\b", r"signal\s+an_trig_delay_d\b",
    r"signal\s+an_trig_delay_dd\b", r"signal\s+an_trig_delay_max\b",
    r"signal\s+an_trig_delay_min\b",
    r"signal\s+ets_on\b", r"signal\s+ets_on_d\b",
    r"signal\s+ets_test\b",
    # ADC interleaving
    r"signal\s+adc_interleaving\b",
    r"signal\s+adc_interleaving_d\b",
    # lut_delay
    r"signal\s+lut_delay_rst",
    # CORDIC
    r"signal\s+cordic_complete",
    # LA
    r"signal\s+LA_",
]

for pat in sig_patterns_to_remove:
    for i in find_signal_lines(lines, pat):
        remove_lines.add(i)

# 6. Also remove KEEP/ASYNC_REG attributes for removed signals
attr_patterns = [
    r"attribute.*awg[12]_phase_trig",
    r"attribute.*an_trig_d\b",
    r"attribute.*an_trig_delay",
    r"attribute.*digitalPattern",
]
for pat in attr_patterns:
    for i, line in enumerate(lines):
        if re.search(pat, line, re.IGNORECASE):
            # Remove attribute line + possibly the next line if blank
            remove_lines.add(i)

# 7. Find instantiations to remove
inst_patterns = [
    (r"signal_generator_inst", r"^\s*\);\s*$"),  # awg_core
    (r"pwm_output_inst", r"^\s*\);\s*$"),  # pwm
    (r"lut_delay_inst", r"^\s*\);\s*$"),  # lut_delay
    (r"dig_pattern_gen_inst", r"^\s*\);\s*$"),  # dig_pattern_gen
    (r"LA_core_inst", r"^\s*\);\s*$"),  # LA_core
]

for start_pat, end_pat in inst_patterns:
    for i, line in enumerate(lines):
        if re.search(start_pat, line):
            # Find the ); that closes this instantiation
            j = i
            depth = 0
            found = False
            while j < len(lines):
                if "port map" in lines[j].lower():
                    depth += 1
                if depth > 0 and ");" in lines[j]:
                    # Check this isn't inside a comment
                    for k in range(i, j + 1):
                        remove_lines.add(k)
                    found = True
                    print(f"  Removing instantiation: {start_pat} (lines {i+1}-{j+1})")
                    break
                j += 1
            if found:
                break

# Also find and remove se_to_ddr instantiation
for i, line in enumerate(lines):
    if re.search(r"se_to_ddr_inst", line):
        j = i
        while j < len(lines) and ");" not in lines[j]:
            j += 1
        if j < len(lines):
            for k in range(i, j + 1):
                remove_lines.add(k)
            print(f"  Removing instantiation: se_to_ddr (lines {i+1}-{j+1})")
        break

# Also find and remove SDP_BRAM_custom_signal instantiation
for i, line in enumerate(lines):
    if re.search(r"SDP_BRAM_custom_signal.*port map", line, re.IGNORECASE):
        depth = 0
        j = i
        for k in range(i, len(lines)):
            if "port map" in lines[k].lower():
                depth += 1
            if depth > 0 and ");" in lines[k]:
                # Remove from i to k
                for m in range(i, k + 1):
                    remove_lines.add(m)
                print(f"  Removing SDP_BRAM_custom_signal (lines {i+1}-{k+1})")
                break

# 8. Find clk_gen_pll/clk_wiz_0 instances to remove
for inst_name in ["clk_gen_pll_inst", "clk_wiz_0_inst"]:
    for i, line in enumerate(lines):
        if re.search(inst_name, line):
            j = i
            while j < len(lines) and ");" not in lines[j]:
                j += 1
            if j < len(lines):
                for k in range(i, j + 1):
                    remove_lines.add(k)
                print(f"  Removing instantiation: {inst_name} (lines {i+1}-{j+1})")
            break

# ── Now build output ──
output = []
i = 0
while i < len(lines):
    if i in remove_lines:
        i += 1
        continue

    line = lines[i]

    # Replace entity port block with new ports
    if i == entity_port_start:
        output.append(NEW_PORTS + "\n")
        i += 1
        # Skip until after old port block
        while i < len(lines) and ");" not in lines[i-1]:
            i += 1
        continue

    # Replace ADC component
    if i == adc_comp_pos:
        output.append(NEW_ADC_COMPONENT + "\n")
        i += 1
        while i < len(lines) and not re.search(r"end\s+component", lines[i], re.IGNORECASE):
            i += 1
        i += 1  # Skip end component line
        continue

    # Replace SPI component
    if i == spi_comp_pos:
        output.append(NEW_SPI_COMPONENT + "\n")
        i += 1
        while i < len(lines) and not re.search(r"end\s+component", lines[i], re.IGNORECASE):
            i += 1
        i += 1  # Skip end component line
        continue

    # Replace ADC data signal declarations (10-bit → 14-bit)
    if re.search(r"signal\s+dataA\s*:", line) and 'std_logic_vector(9' in line:
        output.append("	signal dataA : std_logic_vector(13 downto 0); -- ADC上沿数据\n")
        i += 1; continue
    if re.search(r"signal\s+dataB\s*:", line) and 'std_logic_vector(9' in line:
        output.append("	signal dataB : std_logic_vector(13 downto 0); -- ADC下沿数据\n")
        i += 1; continue
    if re.search(r"signal\s+dataAd\s*:", line) and '9' in line:
        output.append("	signal dataAd : std_logic_vector(13 downto 0); -- ADC CH1上沿\n")
        i += 1; continue
    if re.search(r"signal\s+dataBd\s*:", line) and '9' in line:
        output.append("	signal dataBd : std_logic_vector(13 downto 0); -- ADC CH2下沿\n")
        i += 1; continue

    # Replace mavg data widths (10-bit → 14-bit)
    if re.search(r"signal\s+mavg_dataA\s*:", line) and '9' in line:
        output.append("	signal mavg_dataA : std_logic_vector(13 downto 0);\n")
        i += 1; continue
    if re.search(r"signal\s+mavg_dataB\s*:", line) and '9' in line:
        output.append("	signal mavg_dataB : std_logic_vector(13 downto 0);\n")
        i += 1; continue

    # Replace ADC data mux for 14-bit
    line = re.sub(r"dataAd\s*<=\s*adc_data_rise\s*\(\s*9\s+downto\s+0\s*\)",
                  "dataAd <= adc_data_rise(13 downto 0)", line)
    line = re.sub(r"dataBd\s*<=\s*adc_data_fall\s*\(\s*9\s+downto\s+0\s*\)",
                  "dataBd <= adc_data_fall(13 downto 0)", line)

    # Change ADC generic map from 10 to 14
    line = re.sub(r"ADC_BITS\s*=>\s*10", "ADC_BITS => 14", line)

    # Change mavg_len_log references if needed (check what values are used)
    line = re.sub(r"mavg_len_log\s*=>\s*2", "mavg_len_log => 2", line)  # keep same for now

    # Replace old ADC SPI 16-bit with 24-bit
    line = re.sub(r"SPI_LENGTH\s*=>\s*16", "SPI_LENGTH => 24", line)
    line = re.sub(r"spi_data\s*=>\s*adc_spi_data\b",
                  "spi_data => adc_spi_data_24bit", line)

    # ADC data packing in sample_encoder: update from 10-bit to 14-bit
    # data_in => std_logic_vector(dataAd) & std_logic_vector(dataBd) & dataDd(11 downto 0)
    # → data_in => std_logic_vector(dataAd) & std_logic_vector(dataBd) & "0000"
    line = re.sub(r"std_logic_vector\(dataAd\)\s*\(9 downto 0\)\s*&",
                  "std_logic_vector(dataAd) &", line)
    line = re.sub(r"std_logic_vector\(dataBd\)\s*\(9 downto 0\)\s*&",
                  "std_logic_vector(dataBd) &", line)
    line = re.sub(r"dataDd\(11 downto 0\)\s*\)",
                  '"0000")', line)
    line = re.sub(r"& dataDd\(11 downto 0\)",
                  '& "0000"', line)

    # Replace trig_level signal width (10→14-bit relevant bits)
    # Keep 10-bit trigger comparison from 14-bit ADC (bits [13:4])
    if re.search(r"signal\s+trig_level\s*:", line) and '9' in line:
        output.append("	signal trig_level : SIGNED (9 downto 0);\n")
        i += 1; continue
    if re.search(r"signal\s+trig_hysteresis\s*:", line) and '9' in line:
        output.append("	signal trig_hysteresis : SIGNED (9 downto 0);\n")
        i += 1; continue

    output.append(line)
    i += 1

# ── Write output ──
with open(DST, "w", encoding="utf-8") as f:
    for line in output:
        f.write(line)

print(f"\nWrote {len(output)} lines to {DST}")
print(f"Removed {len(remove_lines)} lines")
print("Done. Manual fixes still needed for state machine sections.")
