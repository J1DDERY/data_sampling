#!/usr/bin/env python3
"""
Transform ScopeFun_core - 副本.vhd -> minimal changes for AD9643 hardware.
Principle: keep everything from backup, only change what hardware requires.
"""
import re, sys

SRC = "D:/0_PRJ/Git/data_sampling/FPGA/srcs/sources_1/ScopeFun_core.vhd"

with open(SRC, "r", encoding="utf-8", errors="replace") as f:
    content = f.read()
    lines = content.split("\n")

print(f"Read {len(lines)} lines")

changes = 0

# ── 1. Entity ports: replace ADC, remove unused ──
# Remove old ADC ports and add new ones
# dataA_p(4:0) + dataA_n(4:0) -> data_p(13:0), data_n(13:0)
# dataB_p(4:0) + dataB_n(4:0) -> removed
# adcB_cs -> removed
# digital channels -> removed
# generator DAC -> removed
# analog trigger -> removed
# cc_ab -> removed

new_adc_line = '\t\tdata_p       : in std_logic_vector(13 downto 0);  -- ADC data LVDS p (14-bit)\n\t\tdata_n       : in std_logic_vector(13 downto 0);  -- ADC data LVDS n (14-bit)'

# Find and replace the ADC port section
old_adc_start = '\t\tclk_adc_p     : in STD_LOGIC;           -- ADC clock LVDS p'
old_adc_end = '\t\tadcB_cs\t\t  : out STD_LOGIC;        -- ADC CH2 serial-interface cs#'

# Find the exact lines
for i, line in enumerate(lines):
    if 'clk_adc_p     : in STD_LOGIC;           -- ADC clock LVDS p' in line:
        adc_port_start = i
    if 'adcB_cs\t\t  : out STD_LOGIC;        -- ADC CH2 serial-interface cs#' in line:
        adc_port_end = i
        break

print(f"ADC ports: lines {adc_port_start+1}-{adc_port_end+1}")

# Build new port section
new_ports = [
    '\t\tclk_adc_p     : in STD_LOGIC;           -- ADC clock LVDS p',
    '\t\tclk_adc_n     : in STD_LOGIC;',
    '\t\tdata_p       : in std_logic_vector(13 downto 0);  -- ADC data (LVDS DDR)',
    '\t\tdata_n       : in std_logic_vector(13 downto 0);  -- ADC data',
    '\t\tadc_sclk      : out STD_LOGIC;        -- ADC serial-interface clock',
    '\t\tadc_sdin      : out STD_LOGIC;        -- ADC serial-interface data',
    '\t\tadcA_cs\t\t  : out STD_LOGIC;        -- ADC serial-interface cs#',
]

# Replace lines
lines = lines[:adc_port_start] + new_ports + lines[adc_port_end+1:]
changes += (adc_port_end - adc_port_start + 1) - len(new_ports)
print(f"  ADC ports replaced (+{len(new_ports) - (adc_port_end - adc_port_start + 1)} lines)")

# Remove digital channel ports
remove_port_lines = [
    'dataD', 'dir_11_6', 'dir_5_0',
    'dpot_cs', 'dpot_sck', 'dpot_si',
]
for pat in remove_port_lines:
    lines = [l for l in lines if pat not in l]
    changes += 1
print(f"  Removed digital channel ports")

# Remove generator DAC ports
dac_remove = ['dac_clk_1', 'dac_clk_2', 'dac_en', 'dac_data']
for pat in dac_remove:
    lines = [l for l in lines if pat not in l]
print(f"  Removed generator DAC ports")

# Remove analog trigger + cc_ab + adcB_cs
trig_remove = ['an_trig_p', 'an_trig_n', 'an_trig_level', 'cc_ab']
for pat in trig_remove:
    lines = [l for l in lines if pat not in l]
print(f"  Removed analog trigger + cc_ab ports")

# Fix the "-- Analog switching" comment (was after removed lines)
for i, line in enumerate(lines):
    if '-- Analog switching' in line:
        # Check if next line is ch1_dc
        for j in range(i+1, min(i+5, len(lines))):
            if 'ch1_dc' in lines[j]:
                break
        else:
            # ch1_dc not found nearby, fix comment
            lines[i] = line.replace('-- Analog switching', '-- Analog frontend switching')
        break

# Fix the "-- ADC interface" section comment
for i, line in enumerate(lines):
    if line.strip() == '-- ADC interface' and i < adc_port_start + 5:
        lines[i] = '\t\t-- ADC interface (AD9643: 14-bit dual-channel)'
        break

# Also remove the "-- DIGITAL channels inteface signals" comment and section header
lines = [l for l in lines if '-- DIGITAL channels' not in l]
lines = [l for l in lines if '-- generator DAC' not in l]
lines = [l for l in lines if '-- Analog Trigger for CH-A ETS' not in l]

# ── 2. Remove component declarations ──
comps_to_remove = [
    'awg_core', 'LA_core', 'dig_pattern_gen', 'lut_delay',
    'pwm', 'se_to_ddr', 'clk_gen_pll', 'SDP_BRAM_custom_signal'
]
for comp in comps_to_remove:
    start = None
    for i, line in enumerate(lines):
        if line is None:
            continue
        if f'component {comp}' in line.lower():
            start = i
        if start is not None and line is not None and 'end component' in line.lower() and i > start:
            # Remove from start to end component line
            while start > 0 and (lines[start-1] is None or lines[start-1].strip() == ''):
                start -= 1
            for j in range(start, i+1):
                lines[j] = None
            print(f"  Removed component: {comp} (lines {start+1}-{i+1})")
            break

# Actually remove marked lines
lines = [l for l in lines if l is not None]
print(f"  Lines after component removal: {len(lines)}")

# Compact None lines
lines = [l for l in lines if l is not None]

# Modify ADC component declaration
for i, line in enumerate(lines):
    if 'component adc_if is' in line:
        # Find port declaration
        for j in range(i, min(i+30, len(lines))):
            if 'i_data_1_p' in lines[j] and '4 downto 0' in lines[j]:
                # Replace from component to end component
                new_adc_comp = [
                    '\tcomponent adc_if is',
                    '\t\tgeneric (',
                    '\t\t\tADC_BITS : integer := 14',
                    '\t\t);',
                    '\t\tPort (',
                    '\t\t\ti_clk_p : in STD_LOGIC;',
                    '\t\t\ti_clk_n : in STD_LOGIC;',
                    '\t\t\ti_clk_ref : in std_logic;',
                    '\t\t\ti_reset_n : in std_logic;',
                    '\t\t\ti_en_fifo : in std_logic;',
                    '\t\t\ti_read_calib_start : in std_logic;',
                    '\t\t\ti_read_calib_source : in std_logic;',
                    '\t\t\ti_data_p : in STD_LOGIC_VECTOR (ADC_BITS-1 downto 0);',
                    '\t\t\ti_data_n : in STD_LOGIC_VECTOR (ADC_BITS-1 downto 0);',
                    '\t\t\to_clk : out STD_LOGIC;',
                    '\t\t\to_data_1 : out STD_LOGIC_VECTOR (ADC_BITS-1 downto 0);',
                    '\t\t\to_data_2 : out STD_LOGIC_VECTOR (ADC_BITS-1 downto 0)',
                    '\t\t);',
                ]
                # Find end component
                end_idx = None
                for k in range(j, min(j+30, len(lines))):
                    if 'end component' in lines[k].lower():
                        end_idx = k
                        break
                if end_idx:
                    lines = lines[:i] + new_adc_comp + lines[end_idx+1:]
                    print(f"  Modified adc_if component")
                break
        break

# Modify SPI component to have generic (the backup already has it, just verify)
# Modify mavg component to add DATA_WIDTH generic
for i, line in enumerate(lines):
    if 'component mavg is' in line:
        # Find the port section
        for j in range(i, min(i+20, len(lines))):
            if 'Port (' in lines[j]:
                # Insert generic before Port
                indent = '\t\t'
                new_mavg = [
                    f'{indent}component mavg is',
                    f'{indent}\tgeneric (',
                    f'{indent}\t\tMAX_MAVG_LEN_LOG : integer := 2;',
                    f'{indent}\t\tDATA_WIDTH : integer := 10',
                    f'{indent}\t);',
                    f'{indent}\tPort (',
                ]
                # Find where Port is and replace from component line
                end_comp = None
                for k in range(j, min(j+30, len(lines))):
                    if 'end component' in lines[k].lower():
                        end_comp = k
                        break
                if end_comp:
                    # Keep existing Port lines, just fix header
                    for pi in range(i, j):
                        lines[pi] = None
                    lines[i] = new_mavg[0]
                    lines[i+1:i+5] = new_mavg[1:5]
                    # Remove None markers
                    lines = [l for l in lines if l is not None]
                    print(f"  Modified mavg component")
                break
        break

# ── 3. Signal declarations ──
# Add adc_data_rise/fall signals
# Find a good insertion point (near dataA/dataB signals)
for i, line in enumerate(lines):
    if 'signal dataA : std_logic_vector(9 downto 0)' in line:
        # Insert after this line
        new_sigs = [
            '\tsignal adc_data_rise : std_logic_vector(13 downto 0); -- ADC rising edge data',
            '\tsignal adc_data_fall : std_logic_vector(13 downto 0); -- ADC falling edge data',
        ]
        lines = lines[:i+1] + new_sigs + lines[i+1:]
        print(f"  Added adc_data_rise/fall signals")
        break

# Remove AWG/LA/digital/ETS/an_trig/interleaving/clk_gen/cordic/SDP_BRAM/dpot signals
sig_remove_patterns = [
    # AWG
    'dac_data_1', 'dac_data_2', 'dac_clk ;', 'dac_clk_1_i', 'dac_clk_2_i', 'dac_en_i',
    'wea_awg', 'addra_awg', 'dina_awg', 'addrb_awg', 'doutb_awg',
    'awg1_phase_trig', 'awg2_phase_trig',
    'generator1On', 'generator2On', 'genSignal_1', 'genSignal_2',
    'generator1Type', 'generator2Type', 'generator1Voltage', 'generator2Voltage',
    'generator1Offset', 'generator2Offset', 'generator1Delta', 'generator2Delta',
    'generator1Duty', 'generator2Duty',
    'phase_val_1', 'phase_val_2', 'phase_sync',
    'sig_out_enable',
    # LA / digital
    'digitalPatternOutput', 'digitalPatternComplete',
    'digitalClkDivide', 'digital_Direction', 'digital_OutputWord', 'digital_OutputWordMask',
    'digital_WiperCode', 'digitalDirection',
    'dt_triggered', 'dt_enable', 'dtSerial', 'dtSerialCh', 'dt_stage', 'dt_delay',
    'digital_trig_patternA', 'digital_trig_mask',
    'doutb_dig', 'wea_dig', 'addra_dig', 'dina_dig', 'addrb_dig',
    # ETS / analog trigger
    'ets_on ;', 'ets_on_d ;', 'ets_test',
    'an_trig_d ;', 'an_trig_dd ;', 'an_trig_ddd ;', 'an_trig_dddd ;',
    'an_trig_delay ;', 'an_trig_delay_d ;', 'an_trig_delay_dd ;',
    'an_trig_delay_max', 'an_trig_delay_min',
    'lut_delay_rst', 'lut_reg_out',
    # Interleaving
    'adc_interleaving ;', 'adc_interleaving_d ;',
    # clock gen
    'clk_gen ;',
    # CORDIC
    'cordic_complete',
    # BRAM custom
    'SDP_BRAM_custom',
    # DPOT
    'dpot_spi',
    # Second ADC SPI
    'adcB_spi',
    # Digital I/O
    'dataD ;', 'dataDd ;', 'dataD1d',
    'dir_11_6_i', 'dir_5_0_i',
    # Other AWG signals
    'BufferSel ;',
    'accumulate_addra',
]

for pat in sig_remove_patterns:
    new_lines = []
    removed_count = 0
    for line in lines:
        if pat in line and 'signal' in line.lower():
            removed_count += 1
            continue
        new_lines.append(line)
    lines = new_lines
    if removed_count > 0:
        changes += removed_count

print(f"  Removed AWG/LA/digital/ETS signal declarations")

# Remove KEEP/ASYNC_REG attributes for removed signals
attr_remove = [
    'attribute KEEP of an_trig_d',
    'attribute KEEP of an_trig_delay',
    'attribute KEEP of awg',
    'attribute KEEP of digitalPattern',
    'attribute ASYNC_REG of digitalPattern',
]
lines = [l for l in lines if not any(attr in l for attr in attr_remove)]

# ── 4. Remove instantiations ──
inst_to_remove = [
    'awg_custom_signal', 'awg2_custom_signal', 'dig_custom_signal',
    'lut_delay_inst', 'signal_generator_inst', 'dac_interface',
    'pwm_output_inst', 'dpot_spi_interface', 'logic_analyzer',
    'dig_pattern_gen_0', 'config2_RAM',
]
n# Compact before instantiation removal
lines = [l for l in lines if l is not None]
for inst in inst_to_remove:
    start = None
    for i, line in enumerate(lines):
        if inst in line and ('port map' in line.lower() or ':' in line):
            # Find the instantiation block
            # First find the instance label line
            inst_start = i
            # Walk back to find instance label
            while inst_start > 0 and ':' not in lines[inst_start]:
                inst_start -= 1
            # Find the closing );
            inst_end = inst_start
            depth = 0
            for j in range(inst_start, min(inst_start+50, len(lines))):
                if 'port map' in lines[j].lower():
                    depth += 1
                if depth > 0 and ');' in lines[j]:
                    inst_end = j
                    break
            if inst_end > inst_start:
                # Mark for removal (including blank line before if exists)
                if inst_start > 0 and lines[inst_start-1].strip() == '':
                    inst_start -= 1
                for j in range(inst_start, inst_end+1):
                    lines[j] = None
                print(f"  Removed instantiation: {inst} (lines {inst_start+1}-{inst_end+1})")
                break

# Actually remove None markers
lines = [l for l in lines if l is not None]

# Fix: modify the clk_wiz_0_pll instantiation to remove clk_out2
for i, line in enumerate(lines):
    if 'clk_wiz_0_pll' in line:
        for j in range(i, min(i+20, len(lines))):
            if 'clk_out2' in lines[j]:
                lines[j] = None
                print(f"  Removed clk_out2 from clk_wiz_0_pll")
                break
        break
lines = [l for l in lines if l is not None]

# ── 5. Modify ADC interface instantiation ──
for i, line in enumerate(lines):
    if 'ADC_interface: adc_if' in line or 'ADC_interface : adc_if' in line:
        # Find the port map section
        for j in range(i, min(i+30, len(lines))):
            if 'i_data_1_p' in lines[j]:
                # Replace the ADC instantiation block
                new_adc_inst = [
                    '\tADC_interface: adc_if',
                    '\t\tgeneric map (ADC_BITS => 14)',
                    '\t\tport map (',
                    '\t\t\ti_clk_p => clk_adc_p,',
                    '\t\t\ti_clk_n => clk_adc_n,',
                    '\t\t\ti_clk_ref => clk_ref_i,',
                    '\t\t\ti_reset_n => gl_reset,',
                    '\t\t\ti_en_fifo => \'1\',',
                    '\t\t\ti_read_calib_start => read_calib_start,',
                    '\t\t\ti_read_calib_source => read_calib_source,',
                    '\t\t\ti_data_p => data_p,',
                    '\t\t\ti_data_n => data_n,',
                    '\t\t\to_clk => clk_adc_dclk,',
                    '\t\t\to_data_1 => adc_data_rise,',
                    '\t\t\to_data_2 => adc_data_fall',
                    '\t\t);',
                ]
                # Find end );
                end_idx = None
                for k in range(j, min(j+30, len(lines))):
                    if ');' in lines[k] and k > j:
                        end_idx = k
                        break
                if end_idx:
                    lines = lines[:i] + new_adc_inst + lines[end_idx+1:]
                    print(f"  Modified ADC_interface instantiation")
                break
        break

# ── 6. Add data aliases after ADC instantiation ──
for i, line in enumerate(lines):
    if 'o_data_2 => adc_data_fall' in line:
        # Insert aliases after the closing );
        if i+1 < len(lines) and ');' in lines[i+1]:
            lines.insert(i+2, '\tdataA <= adc_data_rise(9 downto 0); -- 10-bit alias for backward compat')
            lines.insert(i+3, '\tdataB <= adc_data_fall(9 downto 0);')
        break

# ── 7. Modify dataAd/dataBd to use 14-bit ──
for i, line in enumerate(lines):
    if 'signal dataAd :' in line and '9 downto 0' in line:
        lines[i] = '\tsignal dataAd : signed(13 downto 0); -- ADC CH1 signed (14-bit)'
    if 'signal dataBd :' in line and '9 downto 0' in line:
        lines[i] = '\tsignal dataBd : signed(13 downto 0); -- ADC CH2 signed (14-bit)'

# Fix dataA/dataB signal types
for i, line in enumerate(lines):
    if 'signal dataA : std_logic_vector(9 downto 0)' in line:
        lines[i] = '\tsignal dataA : std_logic_vector(13 downto 0); -- ADC rising edge data'
    if 'signal dataB : std_logic_vector(9 downto 0)' in line:
        lines[i] = '\tsignal dataB : std_logic_vector(13 downto 0); -- ADC falling edge data'

# ── 8. Modify sample_encoder instantiation ──
for i, line in enumerate(lines):
    if 'sample_encoder: sample_encoder_32_32' in line or 'sample_encoder : sample_encoder_32_32' in line:
        # Find encoding_format and data_in lines
        for j in range(i, min(i+30, len(lines))):
            if 'encoding_format' in lines[j]:
                lines[j] = '\t\t\tencoding_format => "1111",  -- 14-bit CH1/CH2 passthrough'
            if 'data_in' in lines[j]:
                lines[j] = '\t\t\tdata_in => std_logic_vector(dataAd) & std_logic_vector(dataBd) & "0000",'
        break

# ── 9. Modify mavg instantiations for 14-bit ──
for i, line in enumerate(lines):
    if 'mavg_ch1: mavg' in line or 'mavg_ch1 : mavg' in line:
        for j in range(i, min(i+20, len(lines))):
            if 'generic map' in lines[j]:
                # Add DATA_WIDTH generic
                indent = lines[j][:lines[j].find('generic')]
                lines[j] = f'{indent}generic map ('
                lines.insert(j+1, f'{indent}\tMAX_MAVG_LEN_LOG => 2,')
                lines.insert(j+2, f'{indent}\tDATA_WIDTH => 14')
                # Fix the closing
                for k in range(j+3, min(j+10, len(lines))):
                    if 'port map' in lines[k]:
                        # Insert ) before port map
                        lines.insert(k, f'{indent})')
                        break
                break
        break

for i, line in enumerate(lines):
    if 'mavg_ch2: mavg' in line or 'mavg_ch2 : mavg' in line:
        for j in range(i, min(i+20, len(lines))):
            if 'generic map' in lines[j]:
                indent = lines[j][:lines[j].find('generic')]
                lines[j] = f'{indent}generic map ('
                lines.insert(j+1, f'{indent}\tMAX_MAVG_LEN_LOG => 2,')
                lines.insert(j+2, f'{indent}\tDATA_WIDTH => 14')
                for k in range(j+3, min(j+10, len(lines))):
                    if 'port map' in lines[k]:
                        lines.insert(k, f'{indent})')
                        break
                break
        break

# ── 10. Fix mavg_data signals to 14-bit ──
for i, line in enumerate(lines):
    if 'signal mavg_dataA : std_logic_vector(9 downto 0)' in line:
        lines[i] = '\tsignal mavg_dataA : std_logic_vector(13 downto 0);'
    if 'signal mavg_dataB : std_logic_vector(9 downto 0)' in line:
        lines[i] = '\tsignal mavg_dataB : std_logic_vector(13 downto 0);'

# ── 11. Fix trigger signal source ──
for i, line in enumerate(lines):
    # Change trig_signal to use 14-bit ADC data (bits 13:4)
    if 'trig_signal <=' in line and 'dataAd' in line:
        lines[i] = '\t\t\t\t\ttrig_signal <= signed(dataAd(13 downto 4));  -- 14-bit ADC, use upper 10 bits'
    if 'trig_signal <=' in line and 'dataBd' in line:
        lines[i] = '\t\t\t\t\ttrig_signal <= signed(dataBd(13 downto 4));'

# ── 12. Fix dataAd/dataBd assignments ──
for i, line in enumerate(lines):
    if 'dataAd <= signed(adc_data_rise(9 downto 0))' in line:
        lines[i] = '\t\t\t\tdataAd <= signed(adc_data_rise);  -- 14-bit'
    if 'dataAd <= signed(mavg_dataA)' in line:
        lines[i] = '\t\t\t\tdataAd <= signed(mavg_dataA);  -- 14-bit'
    if 'dataBd <= signed(adc_data_fall(9 downto 0))' in line:
        lines[i] = '\t\t\t\tdataBd <= signed(adc_data_fall);  -- 14-bit'
    if 'dataBd <= signed(mavg_dataB)' in line:
        lines[i] = '\t\t\t\tdataBd <= signed(mavg_dataB);  -- 14-bit'

# ── 13. Fix SPI length for ADC ──
for i, line in enumerate(lines):
    if 'SPI_LENGTH => 24' in line and ('ADC' in lines[i-2] or 'ADC' in lines[i-3] or 'ADC' in lines[i-1]):
        pass  # Already 24-bit, keep
    if 'ADC_CH1_spi_interface: spi' in line or 'ADC_CH1_spi_interface : spi' in line:
        for j in range(i, min(i+20, len(lines))):
            if 'generic map' in lines[j]:
                # Ensure SPI_LENGTH => 24
                for k in range(j, min(j+5, len(lines))):
                    if 'SPI_LENGTH' in lines[k]:
                        lines[k] = '\t\tgeneric map (SPI_LENGTH => 24)  -- AD9643: 24-bit AN-877'
                        break
                break
        break

# ── 14. Fix adcB_cs assignments ──
lines = [l for l in lines if 'adcB_cs' not in l]

# ── 15. Fix cc_ab assignment ──
lines = [l for l in lines if 'cc_ab' not in l]

# ── 16. Fix frame header words ──
for i, line in enumerate(lines):
    # Word 2: an_trig_delay_dd -> zeros
    if 'an_trig_delay_dd' in line and 'fdata' in line:
        lines[i] = '\t\t\t\t\t\t\t\t\twhen 2 =>'
        # Need to add fdata assignment on next line
        if i+1 < len(lines) and 'fdata' in lines[i+1]:
            lines[i+1] = '\t\t\t\t\t\t\t\t\t\tfdata <= X"00000000"; -- (was an_trig_delay)'
    # Word 3: digitalPatternCompleteCnt_dd -> zeros
    if 'digitalPatternCompleteCnt_dd' in line and 'fdata' in line:
        lines[i] = '\t\t\t\t\t\t\t\t\t\tfdata <= X"00000000"; -- (was digitalPatternCompleteCnt)'
    # Word 4: an_trig_delay_max -> zeros
    if 'an_trig_delay_max' in line and 'fdata' in line:
        lines[i] = '\t\t\t\t\t\t\t\t\t\tfdata <= X"00000000"; -- (was an_trig_delay_max)'

# ── Write output ──
with open(SRC, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))

print(f"\nFinal: {len(lines)} lines")
print(f"Changes made: {changes}")
print("Done. Manual fixes still needed for state machines.")
