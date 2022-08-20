/* -*- P4_16 -*- */
#include <core.p4>
#if __TARGET_TOFINO__ == 2
#include <t2na.p4>
#else
#include <tna.p4>
#endif

#include "headers.p4"
#include "util.p4"

/*************************************************************************
*********************** T Y P E D E F  ***********************************
*************************************************************************/
typedef bit<9>  egressSpec_t;
typedef bit<48> macAddr_t;
typedef bit<32> ip4Addr_t;
#if __TARGET_TOFINO__ == 1
typedef bit<3> mirror_type_t;
#else
typedef bit<4> mirror_type_t;
#endif
typedef bit<8>  pkt_type_t;
const pkt_type_t PKT_TYPE_NORMAL = 1;
const pkt_type_t PKT_TYPE_MIRROR = 2;
const ether_type_t ETHERTYPE_CD = 16w0x1212;
const ether_type_t ETHERTYPE_SEL = 16w0x1213;
const ether_type_t ETHERTYPE_SELDONE = 16w0x1214;
const mirror_type_t MIRROR_TYPE_I2E = 1;
const mirror_type_t MIRROR_TYPE_E2E = 2;
const bit<8> my_swid = 2;
const bit<1> edge_flag = 1;
const bit<9> input_port = 12;
const bit<9> inside = 16;
const bit<9> outside = 8;
const bit<9> output_port = 0;
const bit<9> next_hop = 16;
const bit<12> next_vid = 3000;

/*************************************************************************
*********************** C O N S T  ***********************************
*************************************************************************/
const bit<32> NUM_RAND1 = 51646229;         // A random prime number used in hash to create diff index
const bit<32> NUM_RAND2 = 122420729;        // A random prime number used in hash to create diff index


/*************************************************************************
*********************** R E G I S T E R  ***********************************
*************************************************************************/
//only for the edge switch
Register<bit<1>, bit<32>>(32w1048576,0) existing_state;
Register<bit<1>, bit<32>>(32w1048576,0) request_version;
Register<bit<1>, bit<32>>(32w1048576,0) flow_time_window;
Register<bit<1>, bit<32>>(32w1048576,0) link_time_window;
Register<bit<16>, bit<32>>(32w65536,0) flow_bigtime;
Register<bit<32>, bit<32>>(32w1) my_load;

Register<bit<8>, bit<32>>(32w65536) flow_ds_depth;   //CMS, the stored number may be big, should we only use it for modification stage. Normally, use table action to store depth

//flowsz/flow_rate
Register<bit<32>, bit<32>>(32w140056) flowrate1_0;
Register<bit<32>, bit<32>>(32w140056) flowrate1_1;
Register<bit<32>, bit<32>>(32w140056) flowrate1_2;
Register<bit<32>, bit<32>>(32w140056) flowrate1_3;
Register<bit<32>, bit<32>>(32w140056) flowrate2_0;
Register<bit<32>, bit<32>>(32w140056) flowrate2_1;
Register<bit<32>, bit<32>>(32w140056) flowrate2_2;
Register<bit<32>, bit<32>>(32w140056) flowrate2_3;
Register<bit<32>, bit<32>>(32w1024) passing_flow_count;
Register<bit<32>, bit<32>>(32w131072) flowrate4;
//link utilization
Register<bit<32>, bit<16>>(32w1024) linkrate1;
Register<bit<32>, bit<16>>(32w1024) linkrate2;

//blocklist
//Register<bit<32>, bit<32>>(32w1024) queue_suspicious;
Register<bit<1>, bit<32>>(32w1048576, 0) suspicious_list;




/*************************************************************************
*********************** H E A D E R S  ***********************************
*************************************************************************/



header sel_t{ //ip.version = 4+2
	bit<8> depth;
	bit<8> edge_id;
	bit<8> passing_depth;
	bit<8> padding;
	bit<32> sw_load;
}
header monitor_t{ //ip.version = 4+1
	bit<32> depth;
}
header statem_t{ //ip.version = 4+4
	bit<8> depth;
	bit<32> flow_rate1;
	bit<32> flow_rate2;
	bit<32> flow_rate3;
}
header seldone_t{ //ip.version = 4+3
	bit<8> depth;
	bit<8> edge_id;
}
header layer4_t{
    bit<16> src_port;
    bit<16> dst_port;
}
header cd_t{ //ip.version = 4+5
	bit<8> defense_version;
	bit<1> hit;  //is it filled?
	bit<7> req_id;
	bit<32> state1;
}

header mirror_h {
    //pkt_type_t  pkt_type;
	bit<8> depth;
	bit<8> edge_id;
}

header bridge_md_t{
bit<8> cur_id;
bit<8> filter;     //0:in blocklist; 1:captured by itself; 2:from outside; 3:output outside; 4: a new flow; 5: in cache 6: remove the extra header 7:mirror to edge switch
bit<16> cur_port;
bit<32> flowkey;
bit<32> cur_load;
bit<32> r_flowkey;
//bit<32> cur_port_ts;
}
struct metadata_t {
//new_proc_param_pos
    /* empty */
    pkt_type_t pkt_type;
	bit<8> depth;
	bit<8> edge_id;
    MirrorId_t ing_mir_ses;   // Ingress mirror session ID
    MirrorId_t egr_mir_ses;   // Egress mirror session ID
	bit<8> protocol;
}

struct headers {
    ethernet_h   ethernet;
	vlan_tag_h	vlan_tag;
    ipv4_h      ipv4;
	monitor_t    monitor;
    sel_t        sel;
	seldone_t    seldone;
	statem_t      statem;
    cd_t 	 cd;
	layer4_t layer4;
//add_headers_pos
}
/*************************************************************************
*********************** P A R S E R  ***********************************
*************************************************************************/

parser SwitchIngressParser(
        packet_in pkt,
        out headers hdr,
        out metadata_t meta,
        out ingress_intrinsic_metadata_t ig_intr_md) {

    TofinoIngressParser() tofino_parser;

    state start {
        tofino_parser.apply(pkt, ig_intr_md);
        transition parse_ethernet;
    }
	state parse_ethernet{
		pkt.extract(hdr.ethernet);
		transition select(hdr.ethernet.ether_type){
			0x800: parse_ipv4;
			0x8100: parse_vlan;
			default: accept;
		}
	}
	state parse_vlan{
		pkt.extract(hdr.vlan_tag);
		transition select(hdr.vlan_tag.ether_type){
			0x800: parse_ipv4;
			default: accept;
		}
			
	}
	state parse_ipv4{
		pkt.extract(hdr.ipv4);
		meta.protocol=hdr.ipv4.protocol;
		transition select(hdr.ipv4.version){
			4:    parse_pre_layer4;
			5:    parse_monitor;
			10:    parse_sel;
			7:    parse_seldone;
			8:    parse_statem;
			9:    parse_cd;
			default:		reject;
		}
    }
    state parse_monitor{
        pkt.extract(hdr.monitor);
		transition select(meta.protocol){
			6: parse_layer4;
			17: parse_layer4;
			default: accept;
		}
    }
    state parse_sel{
		pkt.extract(hdr.sel);
		transition select(meta.protocol){
			6: parse_layer4;
			17: parse_layer4;
			default: accept;
		}
    }
    state parse_seldone{
		pkt.extract(hdr.seldone);
		transition select(meta.protocol){
			6: parse_layer4;
			17: parse_layer4;
			default: accept;
		}
    }
    state parse_statem{
		pkt.extract(hdr.statem);
		transition select(meta.protocol){
			6: parse_layer4;
			17: parse_layer4;
			default: accept;
		}
    }
    state parse_cd{
        pkt.extract(hdr.monitor);
		pkt.extract(hdr.cd);
		transition select(meta.protocol){
			6: parse_layer4;
			17: parse_layer4;
			default: accept;
		}
    }
	state parse_pre_layer4{
        pkt.extract(hdr.layer4);
        transition select(meta.protocol){
			6: parse_layer4;
			17: parse_layer4;
			default: accept;
		}
    }
	
    state parse_layer4{
        pkt.extract(hdr.layer4);
        transition accept;
    }
}

/*************************************************************************
**************  I N G R E S S   P R O C E S S I N G   *******************
*************************************************************************/

control SwitchIngress(
        inout headers hdr,
        inout metadata_t meta,
        in ingress_intrinsic_metadata_t ig_intr_md,
        in ingress_intrinsic_metadata_from_parser_t ig_prsr_md,
        inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
        inout ingress_intrinsic_metadata_for_tm_t ig_tm_md) {
	bit<1> local_hit = 0;
	bit<1> is_blocked = 0;
	bit<1> blocklist_update = 0;
	bit<1> old_blockstate = 0;
	bit<1> filter_idx = 0;
	bit<1> is_incache = 0;
	bit<1> last_hop = 0;
	bit<1> stale_flag = 0;
	bit<1> select_flag = 0;
	bit<1> last_ver = 0;
	bit<16> last_time = 0;
	bit<16> cur_big_time = 0;
	bit<1> being_congested = 0;
	bit<1> cache_monitor_flag = 0;
	bit<1> flow_monitor_flag = 0;
	bit<2> cur_cache_flag = 0;
	bit<1> global_time_window = 0;
	bit<1> cur_flow_time_window = 0;
	bit<1> cur_cache_time_window = 0;
	bit<1> cur_link_time_window = 0;
	bit<1> my_load_flag = 0;
	bit<2> local_state_flag = 0;
	bit<8> depth_to_update = 0;
	bit<8> depth_get = 0;
	bit<1> flow_ds_depth_flag = 0;
	bit<32> flowkey_5tuple = 0;
	bit<32> flowkey_2tuple = 0;
	bit<32> record_key_0 = 0;
	bit<32> record_key_1 = 0;
	bit<32> record_key_2 = 0;
	bit<32> dup_filter_key = 0;
	bit<32> suspicious_key = 0;
	bit<32> flow_ds_depth_key = 0;
	bit<32> my_cache_index_update_key = 0;
	bit<32> cur_port_index = 0;
	bit<32> cur_port_index_dup = 0;
	bit<32> cur_load = 0;
	bit<32> load_to_update = 0;
	bit<32> cur_passing_flow_cnt = 0;
	bit<32> lstate_to_update = 0;
	bit<32> fstate1_to_update = 0;
	bit<32> fstate2_to_update = 0;
	bit<32> f_r_state1_to_update = 0;
	bit<32> f_r_state2_to_update = 0;
	bit<32> fstate3_to_update = 0;
	bit<32> fstate4_to_update = 0;
	bit<32> cache1_value = 0;
	bit<32> cache2_value = 0;
	bit<32> cache3_value = 0;
	bit<16> cur_cache_index = 0;
	bit<32> cur_cache_index32 = 0;
	bit<16> flow_state4 = 0;
	bit<32> flow_state_0 = 0;
	bit<32> flow_state_1 = 0;
	bit<32> flow_state_2 = 0;
	bit<32> link_state = 0;
	bit<2> link_update_version = 0;
	bit<1> flow_update_version = 0;
	bit<1> cache_update_version = 0;
	bit<8> state2_update_version = 0;
	bit<32> flowstate2_to_update = 0;
	bit<32> flow2_state = 0;
	bit<1> cur_req_ver = 0;
	bit<1> has_returned = 0;
	bit<8> cur_defense_type = 0;
	bit<7> cur_req_id = 0;
	bit<1> being_requested = 0;
	bit<32> reduce_key= 0;
	bit<2> flow_level = 0;
	//request_version_flow
	
	//suspicious_list 
	RegisterAction<bit<1>, bit<32>, bit<1>>(suspicious_list) suspicious_r = {
        void apply(inout bit<1> value, out bit<1> read_value){
            read_value = value;
        }
    };	
	RegisterAction<bit<1>, bit<32>, bit<1>>(suspicious_list) suspicious_w = {
        void apply(inout bit<1> value, out bit<1> read_value){
			read_value = value;
			value = 1;
        }
    };
	RegisterAction<bit<1>, bit<32>, bit<1>>(suspicious_list) suspicious_c = {
        void apply(inout bit<1> value, out bit<1> read_value){
			read_value = value;
			value = 0;
        }
    };
	
	//my_load
	RegisterAction<bit<32>, bit<32>, bit<32>>(my_load) my_load_read = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(my_load) my_load_plus = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = value + 1;
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(my_load) my_load_update = {
        void apply(inout bit<32> value, out bit<32> read_value){
			value = 1;//load_to_update;
        }
    };
	//passing_flow_count
	RegisterAction<bit<32>, bit<32>, bit<32>>(passing_flow_count) passing_flow_count_plus = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = value + 1; 
        }
    };	
	RegisterAction<bit<32>, bit<32>, bit<32>>(passing_flow_count) passing_flow_count_decr = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = value - 1; 
        }
    };	
	RegisterAction<bit<32>, bit<32>, bit<32>>(passing_flow_count) passing_flow_count_update = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = value ; //value_to_update
        }
    };	
	
	RegisterAction<bit<1>, bit<32>, bit<1>>(flow_time_window) flow_time_fill_1 = {
        void apply(inout bit<1> value, out bit<1> read_value){
			read_value = value;
			value = 1; 
        }
    };	
	RegisterAction<bit<1>, bit<32>, bit<1>>(flow_time_window) flow_time_fill_0 = {
        void apply(inout bit<1> value, out bit<1> read_value){
			read_value = value;
			value = 0; 
        }
    };
	
	
	//flowrate 
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate1_0) flowrate1_0_update = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = fstate1_to_update;  
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate1_0) flowrate1_0_plus = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = value + fstate1_to_update;  
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate1_0) flowrate1_0_read = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate1_0) flowrate1_0_clear = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = 0;
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate1_1) flowrate1_1_update = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = fstate1_to_update;  
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate1_1) flowrate1_1_plus = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = value + fstate1_to_update;  
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate1_1) flowrate1_1_read = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate1_1) flowrate1_1_clear = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = 0;
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate1_2) flowrate1_2_update = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = fstate1_to_update;  
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate1_2) flowrate1_2_plus = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = value + fstate1_to_update;  
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate1_2) flowrate1_2_read = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate1_2) flowrate1_2_clear = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = 0;
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate1_3) flowrate1_3_update = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = fstate1_to_update;  
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate1_3) flowrate1_3_plus = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = value + fstate1_to_update;  
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate1_3) flowrate1_3_read = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate1_3) flowrate1_3_clear = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = 0;
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate2_0) flowrate2_0_update = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = fstate2_to_update;  
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate2_0) flowrate2_0_plus = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = value + fstate2_to_update;  
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate2_0) flowrate2_0_read = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate2_0) flowrate2_0_clear = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = 0;
        }
    }; 
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate2_1) flowrate2_1_update = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = fstate2_to_update;  
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate2_1) flowrate2_1_plus = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = value + fstate2_to_update;  
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate2_1) flowrate2_1_read = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate2_1) flowrate2_1_clear = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = 0;
        }
    }; 
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate2_2) flowrate2_2_update = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = fstate2_to_update;  
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate2_2) flowrate2_2_plus = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = value + fstate2_to_update;  
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate2_2) flowrate2_2_read = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate2_2) flowrate2_2_clear = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = 0;
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate2_3) flowrate2_3_update = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = fstate2_to_update;  
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate2_3) flowrate2_3_plus = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = value + fstate2_to_update;  
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate2_3) flowrate2_3_read = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate2_3) flowrate2_3_clear = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = 0;
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate4) flowrate4_plus = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = value + 1;  
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate4) flowrate4_read = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(flowrate4) flowrate4_clear = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = 0;
        }
    };
	
	
	//link_load
	RegisterAction<bit<1>, bit<32>, bit<1>>(link_time_window) link_time_fill_1 = {
        void apply(inout bit<1> value, out bit<1> read_value){
			read_value = value;
			value = 1; 
        }
    };	
	RegisterAction<bit<1>, bit<32>, bit<1>>(link_time_window) link_time_fill_0 = {
        void apply(inout bit<1> value, out bit<1> read_value){
			read_value = value;
			value = 0; 
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(linkrate1) linkrate1_update = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = lstate_to_update;  
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(linkrate1) linkrate1_plus = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = value + lstate_to_update;  
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(linkrate1) linkrate1_read = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(linkrate1) linkrate1_clear = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = 0;
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(linkrate2) linkrate2_update = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = lstate_to_update;  
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(linkrate2) linkrate2_plus = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = value + lstate_to_update;  
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(linkrate2) linkrate2_read = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
        }
    };
	RegisterAction<bit<32>, bit<32>, bit<32>>(linkrate2) linkrate2_clear = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = 0;
        }
    };
	
	
	
	
	action remove_vlan(PortId_t dst_port, bit<48> dst_addr) {
        ig_tm_md.ucast_egress_port = dst_port;
		hdr.ethernet.src_addr=hdr.ethernet.dst_addr;
		hdr.ethernet.dst_addr=dst_addr;
		last_hop = 1;
    }

    action route_nat(PortId_t dst_port, bit<48> dst_addr) {
        ig_tm_md.ucast_egress_port = dst_port;
		hdr.vlan_tag.vid = 1;   //internal packet
		hdr.ethernet.src_addr=hdr.ethernet.dst_addr;
		hdr.ethernet.dst_addr=dst_addr;
    }
	
	table all_route {
        key = {
			ig_intr_md.ingress_port: exact;
        }

        actions = {
            route_nat;
			remove_vlan;
        }
        size = 16;
    }
	
	
	

	
	
	
	/////////////flow_state//////////////////////////
	
		
		//flow_state_window1
		action fstate1_0_update(){
			flowrate1_0_update.execute(record_key_0);
		}
		action fstate1_0_read(){
			flow_state_0[21:0] = flowrate1_0_read.execute(record_key_0)[31:10];
		}
		action fstate1_0_plus(){
			flowrate1_0_plus.execute(record_key_0);
		}
		action fstate1_0_clear(){
			flowrate1_0_clear.execute(record_key_0);
		}
		table flow_state_update1_0{
			key = {
				flow_monitor_flag: exact;
				cur_flow_time_window: exact;
				global_time_window: exact;
				flow_level: exact;
			}
			
			actions = {
				fstate1_0_update;
				fstate1_0_read;
				fstate1_0_plus;
				fstate1_0_clear;
			}
			size = 8;
		}
		action fstate1_1_update(){
			flowrate1_1_update.execute(record_key_0);
		}
		action fstate1_1_read(){
			flow_state_0[21:0] = flowrate1_1_read.execute(record_key_0)[31:10];
		}
		action fstate1_1_plus(){
			flowrate1_1_plus.execute(record_key_0);
		}
		action fstate1_1_clear(){
			flowrate1_1_clear.execute(record_key_0);
		}
		table flow_state_update1_1{
			key = {
				flow_monitor_flag: exact;
				cur_flow_time_window: exact;
				global_time_window: exact;
				flow_level: exact;
			}
			
			actions = {
				fstate1_1_update;
				fstate1_1_read;
				fstate1_1_plus;
				fstate1_1_clear;
			}
			size = 8;
		}
		action fstate1_2_update(){
			flowrate1_2_update.execute(record_key_0);
		}
		action fstate1_2_read(){
			flow_state_0[21:0] = flowrate1_2_read.execute(record_key_0)[31:10];
		}
		action fstate1_2_plus(){
			flowrate1_2_plus.execute(record_key_0);
		}
		action fstate1_2_clear(){
			flowrate1_2_clear.execute(record_key_0);
		}
		table flow_state_update1_2{
			key = {
				flow_monitor_flag: exact;
				cur_flow_time_window: exact;
				global_time_window: exact;
				flow_level: exact;
			}
			
			actions = {
				fstate1_2_update;
				fstate1_2_read;
				fstate1_2_plus;
				fstate1_2_clear;
			}
			size = 8;
		}
		action fstate1_3_update(){
			flowrate1_3_update.execute(record_key_0);
		}
		action fstate1_3_read(){
			flow_state_0[21:0] = flowrate1_3_read.execute(record_key_0)[31:10];
		}
		action fstate1_3_plus(){
			flowrate1_3_plus.execute(record_key_0);
		}
		action fstate1_3_clear(){
			flowrate1_3_clear.execute(record_key_0);
		}
		table flow_state_update1_3{
			key = {
				flow_monitor_flag: exact;
				cur_flow_time_window: exact;
				global_time_window: exact;
				flow_level: exact;
			}
			
			actions = {
				fstate1_3_update;
				fstate1_3_read;
				fstate1_3_plus;
				fstate1_3_clear;
			}
			size = 8;
		}
		//flow_state_window2
		action fstate2_0_update(){
			flowrate2_0_update.execute(record_key_0);
		}
		action fstate2_0_read(){
			flow_state_0[21:0] = flowrate2_0_read.execute(record_key_0)[31:10];
		}
		action fstate2_0_plus(){
			flowrate2_0_plus.execute(record_key_0);
		}
		action fstate2_0_clear(){
			flowrate2_0_clear.execute(record_key_0);
		}
		table flow_state_update2_0{
			key = {
				flow_monitor_flag: exact;
				cur_flow_time_window: exact;
				global_time_window: exact;
				flow_level: exact;
			}
			
			actions = {
				fstate2_0_update;
				fstate2_0_read;
				fstate2_0_plus;
				fstate2_0_clear;
			}
			size = 8;
		}
		action fstate2_1_update(){
			flowrate2_1_update.execute(record_key_0);
		}
		action fstate2_1_read(){
			flow_state_0[21:0] = flowrate2_1_read.execute(record_key_0)[31:10];
		}
		action fstate2_1_plus(){
			flowrate2_1_plus.execute(record_key_0);
		}
		action fstate2_1_clear(){
			flowrate2_1_clear.execute(record_key_0);
		}
		table flow_state_update2_1{
			key = {
				flow_monitor_flag: exact;
				cur_flow_time_window: exact;
				global_time_window: exact;
				flow_level: exact;
			}
			
			actions = {
				fstate2_1_update;
				fstate2_1_read;
				fstate2_1_plus;
				fstate2_1_clear;
			}
			size = 8;
		}
		action fstate2_2_update(){
			flowrate2_2_update.execute(record_key_0);
		}
		action fstate2_2_read(){
			flow_state_0[21:0] = flowrate2_2_read.execute(record_key_0)[31:10];
		}
		action fstate2_2_plus(){
			flowrate2_2_plus.execute(record_key_0);
		}
		action fstate2_2_clear(){
			flowrate2_2_clear.execute(record_key_0);
		}
		table flow_state_update2_2{
			key = {
				flow_monitor_flag: exact;
				cur_flow_time_window: exact;
				global_time_window: exact;
				flow_level: exact;
			}
			
			actions = {
				fstate2_2_update;
				fstate2_2_read;
				fstate2_2_plus;
				fstate2_2_clear;
			}
			size = 8;
		}
		action fstate2_3_update(){
			flowrate2_3_update.execute(record_key_0);
		}
		action fstate2_3_read(){
			flow_state_0[21:0] = flowrate2_3_read.execute(record_key_0)[31:10];
		}
		action fstate2_3_plus(){
			flowrate2_3_plus.execute(record_key_0);
		}
		action fstate2_3_clear(){
			flowrate2_3_clear.execute(record_key_0);
		}
		table flow_state_update2_3{
			key = {
				flow_monitor_flag: exact;
				cur_flow_time_window: exact;
				global_time_window: exact;
				flow_level: exact;
			}
			
			actions = {
				fstate2_3_update;
				fstate2_3_read;
				fstate2_3_plus;
				fstate2_3_clear;
			}
			size = 8;
		}
	
	/////////////flow_state//////////////////////////
	
	/////////////link_state//////////////////////////
		//link_state_window1
		action lstate1_update(){
			linkrate1_update.execute(cur_port_index);
		}
		action lstate1_read(){
			link_state = linkrate1_read.execute(cur_port_index);
		}
		action lstate1_plus(){
			linkrate1_plus.execute(cur_port_index);
		}
		action lstate1_clear(){
			linkrate1_clear.execute(cur_port_index);
		}
		
		table link_state_update1{
			key = {
				cur_link_time_window: exact;
				global_time_window: exact;
			}
			
			actions = {
				lstate1_update;
				lstate1_read;
				lstate1_plus;
				lstate1_clear;
			}
			size = 4;
		}
		
		//link_state_window2
		action lstate2_update(){
			linkrate2_update.execute(cur_port_index);
		}
		action lstate2_read(){
			link_state = linkrate2_read.execute(cur_port_index);
		}
		action lstate2_plus(){
			linkrate2_plus.execute(cur_port_index);
		}
		action lstate2_clear(){
			linkrate2_clear.execute(cur_port_index);
		}
		table link_state_update2{
			key = {
				cur_link_time_window: exact;
				global_time_window: exact;
			}
			
			actions = {
				lstate2_update;
				lstate2_read;
				lstate2_plus;
				lstate2_clear;
			}
			size = 4;
		}
		
		
	/////////////link_state//////////////////////////
	
	
	
	action return_defense_info(bit<1> curv, bit<8> curt, bit<7> curid){
		being_congested = 1;
		cur_req_ver = curv;
		cur_defense_type = curt;   //coremelt
		cur_req_id = curid;
	}
	table get_defense_info{
		key = {
			ig_intr_md.ingress_port: exact;
		}
		actions = {
			return_defense_info;
		}
		size = 2;
	}
	action my_drop(){
		ig_tm_md.ucast_egress_port = 10;
	}

	action return_block_flag(){
		is_blocked = 1;
	}
	table blocktable{
		key = {
			hdr.ipv4.src_addr: exact;
		}
		actions = {
			return_block_flag;
		}
	}
	
	action upload_to_cpu_crossfire(){
		meta.ing_mir_ses = 12; 
		meta.depth[4:4]=1;
		ig_dprsr_md.mirror_type = 1;
	}
	table thre_check_crossfire{
		key = {
			flow_state4 : range;
		}
		actions = {
			upload_to_cpu_crossfire;
		}
	}
	
	CRCPolynomial<bit<32>>(32w0x04C11DB7, // polynomial
                           true,          // reversed
                           false,         // use msb?
                           false,         // extended?
                           32w0xFFFFFFFF, // initial shift register value
                           32w0xFFFFFFFF  // result xor
                           ) poly1;
						   
    Hash<bit<20>>(HashAlgorithm_t.CUSTOM, poly1) hash0;
    Hash<bit<20>>(HashAlgorithm_t.CUSTOM, poly1) hash1;
    Hash<bit<20>>(HashAlgorithm_t.CUSTOM, poly1) hash2;
    Hash<bit<20>>(HashAlgorithm_t.CUSTOM, poly1) hash3;
	bit<32> temp32;
    apply {
		@stage(0){
			global_time_window = ig_prsr_md.global_tstamp[31:31];  //every 2^30 ns ~ 1s
			cur_port_index[8:0] = ig_intr_md.ingress_port;
			cur_port_index_dup[8:0] = ig_intr_md.ingress_port;
			get_defense_info.apply();
			blocktable.apply();
			flowkey_5tuple[19:0] = hash0.get({hdr.ipv4.src_addr, hdr.ipv4.dst_addr, hdr.layer4.src_port, hdr.layer4.dst_port, hdr.ipv4.protocol});
			fstate1_to_update[15:0] = hdr.ipv4.total_len;
			fstate2_to_update[15:0] = hdr.ipv4.total_len;
			lstate_to_update[15:0] = hdr.ipv4.total_len;
			all_route.apply();
			if(hdr.monitor.isValid()){
				if(hdr.monitor.depth == 1){
					flow_monitor_flag = 1;
					hdr.monitor.depth = 0;
				}
				else if(hdr.monitor.depth[7:0] != 0){ //it's captured by later switch
						hdr.monitor.depth = hdr.monitor.depth - 1;
				}
			}
		}
		if(is_blocked == 0 && hdr.ipv4.isValid()){ 
			@stage(1){
				if(global_time_window==0){
					cur_link_time_window = link_time_fill_0.execute(cur_port_index);
					if(flow_monitor_flag == 1)
						cur_flow_time_window = flow_time_fill_0.execute(flowkey_5tuple);
				}
				else{
					cur_link_time_window = link_time_fill_1.execute(cur_port_index);
					if(flow_monitor_flag == 1)
						cur_flow_time_window = flow_time_fill_1.execute(flowkey_5tuple);
				}
				record_key_0[16:0] = flowkey_5tuple[16:0];
				flow_level = flowkey_5tuple[18:17];
			}
			@stage(1){
				if(hdr.ipv4.version == 10){  //sel packet --> sel; sel_done;
					hdr.sel.passing_depth = hdr.sel.passing_depth + 1;
					temp32 = hdr.sel.sw_load;
					if(last_hop == 1){
						meta.ing_mir_ses = 11;   
						ig_dprsr_md.mirror_type = 1;
					}
				}
				else if(hdr.ipv4.version == 8){  //statem packet --> forward; hit and drop;
					if(hdr.statem.depth == 1){
						hdr.statem.setInvalid();
						ig_tm_md.ucast_egress_port = 11; //mean drop
						my_load_flag = 1;
					}
					else
						hdr.statem.depth = hdr.statem.depth - 1;
				}
			}
			@stage(2){
				if(my_load_flag==0)
					cur_load = my_load_read.execute(0);
				else
					my_load_plus.execute(0);
			}
			@stage(3){
				if(hdr.sel.isValid()){
					hdr.sel.sw_load = cur_load - hdr.sel.sw_load;
					@stage(4){
						if(hdr.sel.sw_load[31:31] == 1){ //cur_load < sw_load
							hdr.sel.sw_load = cur_load;
							hdr.sel.depth=hdr.sel.passing_depth;
							meta.depth[0:0] = 1;
						}
						else
							hdr.sel.sw_load = temp32;
					}
				}
			}
			@stage(3){
				link_state_update1.apply();
			}
			@stage(4){
				link_state_update2.apply();
			}
			@stage(5){
				if(hdr.ipv4.version == 10)
					cur_passing_flow_cnt = passing_flow_count_plus.execute(cur_port_index);
			}
			@stage(6){
				if(hdr.ipv4.version==4 || hdr.ipv4.version==5){
					if(link_state[31:10] == 0 && cur_defense_type == 1)  // link_load < 8Mbps or has been in defense mode
					{
						meta.ing_mir_ses = 12;   
						ig_dprsr_md.mirror_type = 1;
						meta.edge_id=cur_port_index[7:0];
						meta.depth[2:2] = 1;
					}
					else if (link_state[31:10] != 0 && cur_passing_flow_cnt[31:2] != 0 && cur_defense_type == 0){ //it's just congested
						meta.ing_mir_ses = 12;   
						ig_dprsr_md.mirror_type = 1;
						meta.edge_id=cur_port_index[7:0];
						meta.depth[1:1] = 1;
					}
				}
			}
			@stage(2){
				flow_state_update1_0.apply();
			}
			@stage(3){
				flow_state_update2_0.apply();
			}
			@stage(4){
				flow_state_update1_1.apply();
			}
			@stage(5){
				flow_state_update2_1.apply();
			}
			@stage(6){
				flow_state_update1_2.apply();
			}
			@stage(7){
				flow_state_update2_2.apply();
			}
			@stage(8){
				flow_state_update1_3.apply();
			}
			@stage(9){
				flow_state_update2_3.apply();
			}
			@stage(9){
				if (hdr.ipv4.version==9){
					reduce_key[19:0] = hash3.get({hdr.ipv4.src_addr, hdr.ipv4.dst_addr});
					@stage(10){
						if (hdr.cd.req_id==my_swid[6:0]){
							if((flow_monitor_flag==1 && flow_state_0 == 0) || (hdr.cd.hit==1 && hdr.cd.state1 == 1)){ //capture by itself
								flow_state4=flowrate4_plus.execute(reduce_key)[18:3]; // > 8 
								hdr.cd.hit=0;
							}
							else{ 
								hdr.cd.hit = 1; //a tag, have passed req_switch
								hdr.cd.state1 = 0; //a tag, don't return if state1 = 0
							} 
							@stage(11){
								thre_check_crossfire.apply();
							}
						}
						else{//before and behind
							if(flow_monitor_flag==1 && flow_state_0 == 0){ //mask hdr.cd.hit
								hdr.cd.hit=1;
								hdr.cd.state1=1;
							}
							@stage(11){
								if(last_hop == 1) //handle some special cases
								{
									if(hdr.cd.hit==1 && hdr.cd.state1 == 1){ //should care
										//mirror_action, nothing need to save 
										meta.ing_mir_ses = 11;   // 10 --> 10; special mirror port
										meta.edge_id[6:0]=hdr.cd.req_id;
										ig_dprsr_md.mirror_type = 1;
									}
								}
							}
						}
					}
				}
			}
			@stage(11){
				if(last_hop == 1){
					hdr.ipv4.version = 4;
					hdr.ethernet.ether_type = 0x800;
					hdr.vlan_tag.setInvalid();
					hdr.sel.setInvalid();
					hdr.monitor.setInvalid();
					hdr.cd.setInvalid();
					hdr.statem.setInvalid();
				}
			}
		}
		ig_tm_md.bypass_egress = 1w1;
	}
}



control SwitchIngressDeparser(
        packet_out pkt,
        inout headers hdr,
        in metadata_t meta,
        in ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md) {
    Mirror() mirror;
	apply {
		if(ig_dprsr_md.mirror_type == 1){
			mirror.emit<seldone_t>(meta.ing_mir_ses, {meta.depth, meta.edge_id});
		}
         pkt.emit(hdr);
    }
}

parser SwitchEgressParser(
        packet_in pkt,
        out headers hdr,
        out metadata_t eg_md,
        out egress_intrinsic_metadata_t eg_intr_md) {

    TofinoEgressParser() tofino_parser;

    state start {
        tofino_parser.apply(pkt, eg_intr_md);
		mirror_h mirror_md;
		pkt.extract(mirror_md);
		eg_md.edge_id = mirror_md.edge_id;
		eg_md.depth = mirror_md.depth;
		transition parse_ethernet;
	}
	state parse_ethernet{
		pkt.extract(hdr.ethernet);
		transition select(hdr.ethernet.ether_type){
			0x800: parse_ipv4;
			0x8100: parse_vlan;
			default: reject;
		}
	}
	state parse_vlan{
		pkt.extract(hdr.vlan_tag);
		transition parse_ipv4;
	}
    state parse_ipv4{
        pkt.extract(hdr.ipv4);
        transition select(hdr.ipv4.version){
			4:    accept;
			5:    parse_monitor;
			10:    parse_sel;
			7:    parse_seldone;
			8:    parse_statem;
			9:    parse_cd;
			default:		reject;
		}
    }
	state parse_monitor{
        pkt.extract(hdr.monitor);
		transition accept;
    }
    state parse_sel{
		pkt.extract(hdr.sel);
		transition accept;
    }
    state parse_seldone{
		pkt.extract(hdr.seldone);
		transition accept;
    }
    state parse_statem{
		pkt.extract(hdr.statem);
		transition accept;
    }
    state parse_cd{
        pkt.extract(hdr.monitor);
		pkt.extract(hdr.cd);
		transition accept;
    }
}


control SwitchEgressDeparser(
        packet_out pkt,
        inout headers hdr,
        in metadata_t eg_md,
        in egress_intrinsic_metadata_for_deparser_t eg_dprsr_md) {



    apply {
		pkt.emit(hdr);
    }
}


/*************************************************************************
****************  E G R E S S   P R O C E S S I N G   *******************
*************************************************************************/

control SwitchEgress( inout headers hdr,
        inout metadata_t meta,
        in    egress_intrinsic_metadata_t                 eg_intr_md,
        in    egress_intrinsic_metadata_from_parser_t     eg_prsr_md,
        inout egress_intrinsic_metadata_for_deparser_t    eg_dprsr_md,
        inout egress_intrinsic_metadata_for_output_port_t eg_oport_md) {
Register<bit<32>, bit<9>>(32w512,0) link_congestion_window;
bit<32> cur_time=0;
bit<32> last_time=0;
bit<9> link_index=0;
//link_congestion_window
	RegisterAction<bit<32>, bit<9>, bit<32>>(link_congestion_window) link_congestion_window_update = {
        void apply(inout bit<32> value, out bit<32> read_value){
			read_value = value;
			value = cur_time; 
        }
    };	
	action mirror_route(bit<48> dst){
		hdr.ethernet.dst_addr = dst;
	}
    table route_mirror{
		key = {
			meta.edge_id: exact;
		}
		actions = {
			mirror_route;
		}
		size = 8;
	}
	apply{
		@stage(6){
			if(hdr.ipv4.version==10){
				hdr.ipv4.version = 7;
				hdr.seldone.setValid();
				hdr.seldone.edge_id = hdr.sel.edge_id;
				if(meta.depth[0:0] == 1)
					hdr.seldone.depth=hdr.sel.passing_depth+1;
				else
					hdr.seldone.depth=hdr.sel.depth;
				hdr.sel.setInvalid();
			}
			route_mirror.apply();
			//depth 1:congested, 2: normal, 3: reverse 4:suspicious
			if(eg_intr_md.egress_port==10){
				cur_time = eg_prsr_md.global_tstamp[47:16];
				if(meta.depth[4:4]==1)
				link_index[7:0]=meta.edge_id + 256;
			else
				link_index[7:0]=meta.edge_id;
				@stage(7){
					last_time = link_congestion_window_update.execute(link_index);
				}
				@stage(8){
					last_time=cur_time-last_time;
				}
				hdr.ipv4.protocol=meta.edge_id;
				hdr.ipv4.ttl=meta.depth;
				@stage(9){
					if(last_time[31:14]==0) //every 2^(16+14) ns ~ 1s
						eg_dprsr_md.drop_ctl=1;
				}
			}
		}
		
	}
}


/*************************************************************************
***********************  S W I T C H  *******************************
*************************************************************************/
Pipeline(SwitchIngressParser(),
         SwitchIngress(),
         SwitchIngressDeparser(),
         SwitchEgressParser(),
         SwitchEgress(),
         SwitchEgressDeparser()) pipe;

Switch(pipe) main;
