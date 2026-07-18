echo_cmd_end:
run_cmd db "run"
run_cmd_end:
clear_cmd db "clear"
clear_cmd_end:
help_cmd db "help"
help_cmd_end:
reboot_cmd db "reboot"
reboot_cmd_end:
halt_cmd db "halt"
halt_cmd_end:
mem_cmd db "mem"
mem_cmd_end:
peek_cmd db "peek"
peek_cmd_end:
poke_cmd db "poke"
poke_cmd_end:
cpuid_cmd db "cpuid"
cpuid_cmd_end:
uptime_cmd db "uptime"
uptime_cmd_end:
shutdown_cmd db "shutdown"
shutdown_cmd_end:
acpi_cmd db "acpi"
acpi_cmd_end:
color_cmd db "color"
color_cmd_end:
sysinfo_cmd db "sysinfo"
sysinfo_cmd_end:
date_cmd db "date"
date_cmd_end:
time_cmd db "time"
time_cmd_end:
draw_cmd db "draw"
draw_cmd_end:
calc_cmd db "calc"
calc_cmd_end:
cursor_cmd db "cursor"
cursor_cmd_end:
usb_cmd db "usb"
usb_cmd_end:
ls_cmd db "ls"
ls_cmd_end:
dir_cmd db "dir"
dir_cmd_end:
cat_cmd db "cat"
cat_cmd_end:
cd_cmd db "cd"
cd_cmd_end:
rm_cmd db "rm"
rm_cmd_end:
net_cmd db "net"
net_cmd_end:

unknown_msg db "Unknown command: ", 0
break_msg db "^C", 0
run_bad_hex_msg db "Invalid hex byte", 0
run_too_long_msg db "Too many bytes for exec_buffer", 0
reboot_msg db "Rebooting...", 0
halt_msg db "Halted.", 0
shutdown_fail_msg db "Shutdown failed - it's now safe to turn off your computer.", 0
uptime_suffix db " s", 0
rsdp_sig db "RSD PTR "

acpi_rsdp_msg db "RSDP: ", 0
acpi_rev_msg db "ACPI revision: ", 0
acpi_fadt_msg db "FADT: ", 0
acpi_via_xsdt_msg db "(via XSDT) ", 0
acpi_via_rsdt_msg db "(via RSDT) ", 0
acpi_via_scan_msg db "(via scan) ", 0
acpi_pm1a_msg db "PM1a_CNT: ", 0
acpi_pm1b_msg db "PM1b_CNT: ", 0
acpi_space_msg db " ", 0
acpi_io_msg db "(io)", 0
acpi_mem_msg db "(mmio)", 0
acpi_none_msg db "none", 0
acpi_enabled_msg db "ACPI already enabled: ", 0
acpi_yes_msg db "yes", 0
acpi_no_msg db "no", 0
acpi_dsdt_msg db "DSDT: ", 0
acpi_s5_msg db "_S5: ", 0
acpi_found_msg db "found ", 0
acpi_notfound_msg db "not found", 0
acpi_typa_msg db "SLP_TYPa=", 0
acpi_typb_msg db " SLP_TYPb=", 0
acpi_valid_msg db " (valid)", 0
acpi_invalid_msg db " (INVALID)", 0
acpi_badpkg_msg db "_S5 package decode failed (unexpected AML structure)", 0

si_cpu_str db "cpu", 0
si_ram_str db "ram", 0
si_gpu_str db "gpu", 0
si_general_str db "general", 0

sysinfo_cpu_hdr db "-- CPU --", 0
sysinfo_vendor_msg db "Vendor: ", 0
sysinfo_brand_msg db "Model: ", 0
sysinfo_family_msg db "Family: ", 0
sysinfo_model_msg db " Model: ", 0
sysinfo_stepping_msg db " Stepping: ", 0
sysinfo_cores_msg db "Logical CPUs: ", 0
sysinfo_cores_unknown_msg db "unknown (no MADT)", 0
sysinfo_unknown_msg db "unknown", 0

sysinfo_ram_hdr db "-- RAM --", 0
sysinfo_ram_unavailable_msg db "not available (BIOS E820 unsupported)", 0
sysinfo_ram_total_msg db "Usable RAM: ", 0
sysinfo_mb_msg db " MB", 0
sysinfo_ram_regions_msg db "Memory map regions: ", 0

sysinfo_gpu_hdr db "-- GPU --", 0
sysinfo_gpu_found_msg db "PCI ", 0
sysinfo_gpu_bus_msg db " bus ", 0
sysinfo_gpu_dev_msg db " dev ", 0
sysinfo_gpu_func_msg db " func ", 0
sysinfo_gpu_id_msg db " id ", 0
sysinfo_gpu_none_msg db "no display controller found on the PCI bus", 0

; Preset color name table: {name_ptr, name_len, attr_byte}, 17 bytes each,
; ends with a zero name_ptr. Attr byte = white background (0x7) foreground,
; matching VGA_ATTR's black-background scheme (0x0_).
color_names:
    dq color_red,    color_red_end - color_red,    0x04
    dq color_green,  color_green_end - color_green, 0x02
    dq color_blue,   color_blue_end - color_blue,   0x01
    dq color_yellow, color_yellow_end - color_yellow, 0x0E
    dq color_white,  color_white_end - color_white, 0x0F
    dq 0

color_red db "red"
color_red_end:
color_green db "green"
color_green_end:
color_blue db "blue"
color_blue_end:
color_yellow db "yellow"
color_yellow_end:
color_white db "white"
color_white_end:

null_idt_descriptor:
    dw 0
    dq 0

cursor_pos dq 0
text_attr db VGA_ATTR
xhci_cmd_index dd 0
xhci_evt_index dd 0
xhci_evt_cycle db 1
xhci_speed dd 0
xhci_mps dd 0
xhci_xfer_cycle db 1
fs_found db 0
fs_config_val db 0
bulk_in_dci db 0
bulk_out_dci db 0
bulk_in_mps dw 0
bulk_out_mps dw 0
bulk_in_cycle db 1
bulk_out_cycle db 1
bot_tag dd 0
fs_part_lba dd 0
fs_fat_lba dd 0
fs_root_lba dd 0
fs_root_secs dd 0
fs_data_lba dd 0
fs_spc dd 0
fs_cur_cluster dd 0
fs_is_fat32 db 0
fs_is_fat16 db 0
fs_is_exfat db 0
fs_ex_attr db 0
fs_ex_nrem db 0
fs_ex_active db 0
fs_ex_size dd 0
fs_ex_cluster_count dd 0
fs_ex_bitmap_clus dd 0
fs_ex_root_clus dd 0
fs_echo_ex_run dd 0
fs_echo_ex_run_lba dd 0
fs_echo_ex_run_off dd 0
fs_echo_ex_cand_off dd 0
fs_echo_ex_i dd 0
fs_echo_ex_lba dd 0
fs_echo_ex_off dd 0
fs_ex_name_entries dd 0           ; number of 0xC1 name entries = ceil(len/15)
fs_ex_set_entries dd 0            ; total entries in the set = 2 + name entries
; entry set: 0x85 file + 0xC0 stream + up to ceil(255/15)=17 name entries = 19*32 = 608
fs_echo_ex_set times 640 db 0
fs_gpt_ent_lba dd 0
fs_gpt_left dd 0
fs_ex_rootdir_clus dd 0          ; exFAT root directory first cluster (from mount)
; --- cd (current working directory) state: a stack of directory first
; clusters, persisted across commands. Every command re-scans/re-mounts the
; USB device, so the stack is validated against the mounted volume via
; fs_cwd_vol (partition LBA) and dropped if a different volume shows up. ---
fs_cwd_depth dd 0                ; 0 = root
fs_cwd_vol dd 0                  ; fs_part_lba the stack belongs to
fs_cwd_stack times 16 dd 0       ; first cluster per level
fs_cwd_path_len dd 0             ; display path ("/a/b"), best-effort
fs_cwd_path times 256 db 0
fs_in_subdir db 0                ; set by fs_apply_cwd after each mount
fs_want_dir db 0                 ; cat-scanner mode: 1 = match directories (cd)
fs_nc_cur dd 0                   ; fs_next_cluster scratch
; --- rm state ---
fs_rm_recursive db 0
fs_rm_found db 0
fs_rm_is_dir db 0
fs_rm_err db 0                   ; 1 = rm -r queue full, 2 = I/O error mid-free
fs_rm_nofat db 0                 ; exFAT NoFatChain flag of the chain being freed
fs_rm_cluster dd 0               ; target's first cluster
fs_rm_size dd 0                  ; target's size (exFAT contiguous-run length)
fs_rm_set_lba dd 0               ; directory-entry set to mark deleted: sector,
fs_rm_set_off dd 0               ;   byte offset of the first entry,
fs_rm_set_cnt dd 0               ;   and entry count (LFN/secondary + primary)
fs_rm_lfn_cnt dd 0               ; LFN entries accumulated for the current set
fs_rm_i dd 0
fs_rm_lba2 dd 0
fs_rm_off2 dd 0
fs_rm_cur dd 0                   ; chain-free walk: current cluster
fs_rm_next dd 0                  ;   and next cluster / contiguous count
fs_rm_bit dd 0                   ; exFAT bitmap-clear: bit index within sector
fs_rm_bit_lba dd 0               ;   and containing bitmap sector LBA
fs_rm_q_head dd 0                ; FS_RM_QUEUE ring indices (linear, no wrap)
fs_rm_q_tail dd 0
fs_rmw_clus dd 0                 ; rm -r directory walk: dir first cluster,
fs_rmw_size dd 0                 ;   dir size (exFAT), current cluster, LBA,
fs_rmw_cur dd 0                  ;   sectors left in cluster, contiguous
fs_rmw_lba dd 0                  ;   clusters left (exFAT NoFatChain), and
fs_rmw_secs dd 0                 ;   the dir's own NoFatChain flag
fs_rmw_nfleft dd 0
fs_rmw_nofat db 0
; --- NTFS cd/rm state ---
fs_cwd_fstype db 0               ; fs type the cwd stack belongs to (1=FAT 2=exFAT 3=NTFS)
fs_ntfs_dir_ref dd 5             ; MFT record of the directory being walked (5 = root)
fs_ntfs_dir_seq dd 5             ; its sequence number (for new $FILE_NAME parent refs)
fs_ntfs_collect db 0             ; fs_ntfs_walk mode: 1 = push every entry to the rm queue
fs_ntfs_rm_target dd 0           ; MFT record of the rm target
fs_ntfs_rm_ref dd 0              ; MFT record currently being freed
fs_ntfs_cur_dir dd 0             ; rm -r: directory currently being enumerated
fs_ntfs_ent_removed db 0         ; index entries removed from the parent
fs_ntfs_run_cnt dd 0             ; pairs collected in FS_NTFS_RUNS
fs_ntfs_tmp_attr dd 0            ; saved attribute offset across a div/helper call
fs_ntfs_bmp_attr dd 0            ; $Bitmap $DATA attribute offset in FS_MFT_BUF
fs_ntfs_bmp_secidx dd 0          ; cached $Bitmap sector index (0xFFFFFFFF = none)
fs_ntfs_bmp_lba dd 0             ; its LBA
fs_ntfs_bmp_rem dd 0             ; sector-within-cluster while mapping bitmap VCNs
fs_ntfs_bmp_dirty db 0
fs_nvl_offsz dd 0                ; fs_ntfs_vcn_to_lcn run-decode scratch
fs_nvl_len dd 0
fs_ncr_ptr dd 0                  ; fs_ntfs_collect_runs cursor / running LCN
fs_ncr_lcn dd 0
fs_ntfs_ri dd 0                  ; fs_ntfs_free_runs loop state
fs_ntfs_rl_c dd 0
fs_ntfs_rl_len dd 0
fs_nre_attr dd 0                 ; fs_ntfs_remove_entry: attribute offset,
fs_nre_root dd 0                 ;   INDEX_ROOT value offset,
fs_nre_len dd 0                  ;   removed entry length,
fs_nre_mod db 0                  ;   record-modified flag
fs_is_ntfs db 0
fs_mft_lba dd 0
fs_rec_secs dd 0
fs_indx_secs dd 0
fs_run_ptr dd 0
fs_run_lcn dd 0
fs_run_len dd 0
fs_fat_cached dd 0
fs_name_len dd 0
fs_entry_off dd 0
fs_sec_count dd 0
fs_cur_lba dd 0
fs_action db 0
fs_target_name times 11 db 0
fs_target_case db 0
fs_target_raw times 255 db 0
fs_target_raw_len dd 0
fs_target_disp times 255 db 0
fs_ex_name_buf times 255 db 0
fs_cat_found db 0
fs_cat_cluster dd 0
fs_cat_size dd 0
fs_cat_remain dd 0
fs_cat_ntfs_ref dd 0
fs_ntfs_newref dd 0
fs_mftmirr_lba dd 0
fs_ntfs_rec_lba dd 0
fs_ntfs_fn_len dd 0
fs_ntfs_ent_len dd 0
fs_ntfs_secid dd 0
fs_ntfs_sd_len dd 0
fs_ntfs_sd_buf times 256 db 0
fs_ntfs_def_sd:
    db 0x01, 0x00, 0x04, 0x80
    dd 48, 64, 0, 20
    db 0x02, 0x00, 0x1C, 0x00, 0x01, 0x00, 0x00, 0x00
    db 0x00, 0x00, 0x14, 0x00, 0xFF, 0x01, 0x1F, 0x00
    db 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00
    db 0x01, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x20, 0x00, 0x00, 0x00, 0x20, 0x02, 0x00, 0x00
    db 0x01, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x20, 0x00, 0x00, 0x00, 0x20, 0x02, 0x00, 0x00
fs_echo_lba dd 0
fs_echo_off dd 0
fs_echo_have_slot db 0
fs_echo_found db 0
fs_echo_ptr dq 0
fs_echo_len dd 0
fs_echo_cluster dd 0             ; first cluster of the allocated chain
fs_echo_clus dd 0
fs_echo_prev_clus dd 0           ; previous cluster while chaining (0 = none yet)
fs_echo_nclus dd 0              ; number of clusters to allocate for the payload
fs_echo_ci dd 0                 ; cluster-walk index during data write
fs_echo_written dd 0           ; bytes written so far during data write
fs_echo_chunk dd 0            ; bytes copied into the current sector
fs_fatset_clus dd 0            ; fs_*_fat_set helper: target cluster
fs_fatset_val dd 0            ; fs_*_fat_set helper: value to store
fs_fatset_lba dd 0           ; fs_*_fat_set helper: containing FAT sector LBA
; FAT long-file-name (VFAT) write state
fs_lfn_count dd 0              ; number of 0x0F LFN entries to emit
fs_lfn_sum db 0                ; 8.3 short-name checksum
fs_need_lfn db 0              ; 1 when the name doesn't fit a plain 8.3 entry
fs_lfn_i dd 0                 ; LFN build/write loop index
fs_lfn_base dd 0             ; base char index while (de)composing a name
fs_lfn_lastdot dd 0          ; index of last '.' in the name (-1 = none)
fs_lfn_namelen dd 0          ; 8.3-check: chars before the last dot
fs_lfn_extlen dd 0           ; 8.3-check: chars after the last dot
; FAT free-directory-slot run search (create needs LFN entries + 8.3 contiguous)
fs_echo_need_run dd 1        ; number of contiguous free entries required
fs_echo_run dd 0             ; current contiguous free-entry run length
fs_echo_run_lba dd 0         ; LBA of the run's first free entry
fs_echo_run_off dd 0         ; byte offset (within sector) of the run start
; LFN read reconstruction (shared by ls and cat)
fs_lfn_have db 0             ; 1 when an LFN name has been accumulated
fs_lfn_maxlen dd 0           ; reconstructed name length
fs_lfn_buf times 260 db 0    ; reconstructed ASCII name
; dest byte offsets of the 13 UTF-16 chars within a 0x0F LFN entry
fs_lfn_off db 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30
redir_pos dq 0
fs_echo_fname dq 0
echo_data_buf times CMD_BUFFER_SIZE + 1 db 0
cmd_len db 0
cmd_buffer times CMD_BUFFER_SIZE db 0
timer_ticks dq 0
cpuid_vendor times 13 db 0
cpu_brand times 49 db 0
dec_buffer times 21 db 0
pm1a_cnt dq 0
pm1b_cnt dq 0
pm1a_mmio db 0
pm1b_mmio db 0
dsdt_addr dq 0
smi_cmd dq 0
acpi_enable_val db 0
slp_typa dq 0
slp_typb dq 0

; Scratch buffer for `run`'s raw machine code - no execute-permission
; distinction is set up in the page tables, so this is directly callable.
exec_buffer times EXEC_BUFFER_SIZE db 0
shift_state db 0
caps_lock db 0
ctrl_state db 0
extended_pending db 0
; Set by check_break when a Ctrl+C chord is polled during a running command;
; process_command clears it before each dispatch and reports it afterward.
break_pending db 0
; check_break's own Ctrl make/break tracking - separate from ctrl_state, which
; only the IRQ1 path maintains and which never fires while a command runs.
poll_ctrl_state db 0
cmd_cursor db 0
sel_active db 0
sel_anchor db 0
cmd_render_len db 0
cmd_history times CMD_HISTORY_ENTRIES * CMD_BUFFER_SIZE db 0
cmd_history_len times CMD_HISTORY_ENTRIES db 0
cmd_history_write dw 0
cmd_history_count dw 0
cmd_history_pos dw 0
cmd_history_saved times CMD_BUFFER_SIZE db 0
cmd_history_saved_len db 0
line_start_pos dq 0
scroll_offset dw 0
cursor_start_shape db 0
hist_write dw 0
hist_count dw 0
history_buffer times HIST_ROWS * VGA_ROW_BYTES db 0
live_shadow times VGA_SIZE db 0

; Experimental mouse cursor state (see `cursor` command / mouse_isr)
cursor_enabled db 0
mouse_x db 0
mouse_y db 0
mouse_packet times 4 db 0
mouse_packet_idx db 0
mouse_packet_size db 3
mouse_has_wheel db 0
mouse_prev_buttons db 0
mouse_scroll_accum dw 0
cursor_cell_valid db 0
cursor_cell_saved_attr db 0

; US QWERTY set-1 scancode -> lowercase ASCII (0 = unmapped/ignored)
scancode_table:
    db 0, 0, '1', '2', '3', '4', '5', '6', '7', '8'
    db '9', '0', '-', '=', 0x08, 0
    db 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', 0x0D, 0
    db 'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', 39, '`', 0
    db 0x5C, 'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/', 0
    db 0, 0, ' '
scancode_table_end:

; Same layout as scancode_table, but for shift held (uppercase letters,
; shifted symbols). Caps-lock-only adjustment is applied separately in
; keyboard_isr so caps lock doesn't also shift symbols/digits.
shifted_scancode_table:
    db 0, 0, '!', '@', '#', '$', '%', '^', '&', '*'
    db '(', ')', '_', '+', 0x08, 0
    db 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', 0x0D, 0
    db 'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '~', 0
    db '|', 'Z', 'X', 'C', 'V', 'B', 'N', 'M', '<', '>', '?', 0
    db 0, 0, ' '

net_mmio_base   dq 0
net_have_nic    db 0
net_mac_addr    times 6 db 0
net_link_up     db 0
net_dhcp_state  db 0
net_ip          dd 0
net_mask        dd 0
net_gateway     dd 0
net_dns         dd 0
net_lease       dd 0
net_rx_tail     dd 0
net_tx_tail     dd 0
net_pci_bus     db 0
net_pci_dev     db 0
net_pci_func    db 0

dhcp_xid        dd 0
dhcp_offered_ip dd 0
dhcp_server_id  dd 0
broadcast_mac   db 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF

dhcp_msg_type_found   db 0
dhcp_parsed_mask      dd 0
dhcp_parsed_gateway   dd 0
dhcp_parsed_dns       dd 0
dhcp_parsed_lease     dd 0
dhcp_parsed_server_id dd 0
dhcp_parsed_yiaddr    dd 0

