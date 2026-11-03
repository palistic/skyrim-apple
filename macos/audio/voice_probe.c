/* Real XAudio2 COM queue/mixer/callback test with guest buffers and a dummy SDL
 * output device. Only the callback methods are authored native fixture shims.
 */
#include "rt.h"
#include <stdatomic.h>
#include <pthread.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

extern int xaudio2_create(uint32_t clsid, uint32_t *out);
static _Atomic unsigned starts, ends, loops, streams, voice_errors, passes, nonzero_required;
#define TEST_CONTEXTS 9000
static _Atomic unsigned context_starts[TEST_CONTEXTS], context_ends[TEST_CONTEXTS], context_loops[TEST_CONTEXTS];
static _Atomic unsigned end_order[TEST_CONTEXTS], event_order, wrong_callback_thread;
static _Atomic uint64_t callback_thread;
static uint64_t caller_thread;
static uint32_t reentrant_voice, reentrant_state, reentrant_buffer;
static _Atomic unsigned reentrant_result;
static unsigned checks;
#define CHECK(test) do { ++checks; if (!(test)) { fprintf(stderr,"audio voice check failed line %d: %s\n",__LINE__,#test); return 1; } } while (0)
static uint16_t rd16(const uint8_t *p) { return p[0] | p[1] << 8; }
static uint32_t rd32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

static uint32_t method(CPU *, uint32_t, unsigned, unsigned, const uint32_t *);
static void record_callback(void) {
    uint64_t thread=0; pthread_threadid_np(NULL,&thread);
    uint64_t expected=0;
    atomic_compare_exchange_strong(&callback_thread,&expected,thread);
    if(thread==caller_thread || atomic_load(&callback_thread)!=thread) ++wrong_callback_thread;
}
static void pass_start(CPU *c) { record_callback(); ++passes; if (ARG(1)) ++nonzero_required; RET(0,2); }
static void pass_end(CPU *c) { RET(0,1); }
static void stream_end(CPU *c) { record_callback(); ++streams; RET(0,1); }
static void buffer_start(CPU *c) {
    record_callback(); uint32_t ctx=ARG(1);
    if(ctx<TEST_CONTEXTS) ++context_starts[ctx];
    ++starts; RET(0,2);
}
static void buffer_end(CPU *c) {
    record_callback(); uint32_t ctx=ARG(1),order=++event_order;
    ++ends;
    if(ctx<TEST_CONTEXTS) { atomic_store(&end_order[ctx],order); ++context_ends[ctx]; }
    if(ctx==200) {
        /* The flushed-buffer callback may reenter queue operations. A second
         * flush must not erase this pass's other pending callback records. */
        method(c,reentrant_voice,25,1,&reentrant_state);
        unsigned result=M32(reentrant_state+4)==0;
        uint32_t submit[]={reentrant_buffer,0};
        M32(reentrant_buffer+32)=201;
        result &= method(c,reentrant_voice,21,2,submit)==0;
        result &= method(c,reentrant_voice,22,0,NULL)==0;
        method(c,reentrant_voice,25,1,&reentrant_state);
        result &= M32(reentrant_state+4)==0;
        M32(reentrant_buffer+32)=202;
        result &= method(c,reentrant_voice,21,2,submit)==0;
        method(c,reentrant_voice,25,1,&reentrant_state);
        result &= M32(reentrant_state+4)==1;
        atomic_store(&reentrant_result,result?1:2);
    }
    RET(0,2);
}
static void loop_end(CPU *c) {
    record_callback(); uint32_t ctx=ARG(1);
    if(ctx<TEST_CONTEXTS) ++context_loops[ctx];
    ++loops; RET(0,2);
}
static void voice_error(CPU *c) { ++voice_errors; RET(0,3); }

static uint32_t method(CPU *cpu, uint32_t object, unsigned index, unsigned count, const uint32_t *arguments) {
    uint32_t values[12] = {object};
    if (count > 11) rt_fatal("audio test argument overflow");
    if (count) memcpy(values + 1, arguments, count * sizeof(uint32_t));
    return rt_invoke(cpu, M32(M32(object) + 4 * index), (int)count + 1, values);
}

static void get_state(CPU *cpu, uint32_t voice, uint32_t state) {
    method(cpu, voice, 25, 1, &state);
}

static int wait_finished(CPU *cpu, uint32_t voice, uint32_t state, unsigned expected_streams) {
    for (unsigned n = 0; n < 2000; ++n) {
        get_state(cpu, voice, state);
        if (!M32(state + 4) && atomic_load(&streams) >= expected_streams) return 1;
        usleep(1000);
    }
    return 0;
}

static int wait_count(_Atomic unsigned *value, unsigned expected) {
    for(unsigned n=0;n<3000;++n) {
        if(atomic_load(value)>=expected) return 1;
        usleep(1000);
    }
    return 0;
}

static int submit_pcm(CPU *cpu,uint32_t voice,uint32_t buffer,uint32_t data,
                      uint32_t frames,uint32_t ctx,uint32_t flags,uint32_t loop_count) {
    memset(GPTR(buffer),0,36);
    M32(buffer)=flags; M32(buffer+4)=2*frames; M32(buffer+8)=data;
    M32(buffer+24)=frames; M32(buffer+28)=loop_count; M32(buffer+32)=ctx;
    uint32_t args[]={buffer,0};
    return method(cpu,voice,21,2,args)==0;
}

static int flush_regressions(CPU *cpu,uint32_t engine,uint32_t format,uint32_t callback) {
    uint32_t output=gmalloc(4),args[]={output,format,0,0x40000000u,callback,0,0};
    CHECK(method(cpu,engine,8,7,args)==0 && M32(output)!=0);
    uint32_t voice=M32(output),state=gmalloc(16),buffer=gmalloc(36),data=gmalloc(88200);
    uint32_t zero[]={0,0};
    for(unsigned n=0;n<44100;++n) M16(data+2*n)=n&1?0x3000:0xd000;

    /* Stopped voices still deliver flushed ends through the processing
     * thread; EOS and loop flags on removed buffers produce no extra events. */
    unsigned stream_base=atomic_load(&streams),loop_base=atomic_load(&loops);
    CHECK(submit_pcm(cpu,voice,buffer,data,16,10,0x40,2));
    CHECK(submit_pcm(cpu,voice,buffer,data,16,11,0x40,2));
    CHECK(method(cpu,voice,22,0,NULL)==0);
    get_state(cpu,voice,state); CHECK(M32(state+4)==0 && M32(state)==0);
    CHECK(wait_count(&context_ends[11],1));
    CHECK(atomic_load(&context_ends[10])==1 && atomic_load(&context_ends[11])==1);
    CHECK(!atomic_load(&context_starts[10]) && !atomic_load(&context_starts[11]));
    CHECK(!atomic_load(&context_loops[10]) && !atomic_load(&context_loops[11]));
    CHECK(atomic_load(&streams)==stream_base && atomic_load(&loops)==loop_base);
    CHECK(atomic_load(&end_order[10])<atomic_load(&end_order[11]));
    CHECK(submit_pcm(cpu,voice,buffer,data,32,12,0x40,0));
    get_state(cpu,voice,state); CHECK(M32(state+4)==1 && M32(state+8)==0);
    usleep(30000); CHECK(!atomic_load(&context_starts[12])); /* flush did not start it */
    CHECK(method(cpu,voice,19,2,zero)==0);
    CHECK(wait_count(&context_ends[12],1));
    get_state(cpu,voice,state); CHECK(M32(state+8)==32);

    /* A running voice retains its genuinely active buffer. Removed ends must
     * precede that active buffer's normal end, despite submission order. */
    CHECK(submit_pcm(cpu,voice,buffer,data,44100,20,0x40,0));
    CHECK(submit_pcm(cpu,voice,buffer,data,16,21,0x40,2));
    CHECK(submit_pcm(cpu,voice,buffer,data,16,22,0x40,2));
    CHECK(wait_count(&context_starts[20],1));
    stream_base=atomic_load(&streams);loop_base=atomic_load(&loops);
    CHECK(method(cpu,voice,22,0,NULL)==0);
    get_state(cpu,voice,state); CHECK(M32(state+4)==1 && M32(state)==20);
    CHECK(wait_count(&context_ends[22],1));
    CHECK(!atomic_load(&context_ends[20]));
    CHECK(!atomic_load(&context_starts[21]) && !atomic_load(&context_starts[22]));
    CHECK(!atomic_load(&context_loops[21]) && !atomic_load(&context_loops[22]));
    CHECK(atomic_load(&streams)==stream_base && atomic_load(&loops)==loop_base);
    CHECK(wait_count(&context_ends[20],1));
    CHECK(atomic_load(&end_order[21])<atomic_load(&end_order[22]) &&
          atomic_load(&end_order[22])<atomic_load(&end_order[20]));
    CHECK(wait_count(&streams,stream_base+1));
    CHECK(submit_pcm(cpu,voice,buffer,data,16,23,0x40,0));
    CHECK(wait_count(&context_ends[23],1)); /* flush preserved the running state */

    /* Stop while a buffer is active, then flush: the formerly active buffer
     * is now removable and only its end callback is generated. */
    CHECK(submit_pcm(cpu,voice,buffer,data,44100,30,0x40,2));
    CHECK(wait_count(&context_starts[30],1));
    CHECK(method(cpu,voice,20,2,zero)==0);
    stream_base=atomic_load(&streams);loop_base=atomic_load(&loops);
    CHECK(method(cpu,voice,22,0,NULL)==0);
    get_state(cpu,voice,state); CHECK(M32(state+4)==0 && M32(state+8)>32);
    CHECK(wait_count(&context_ends[30],1));
    CHECK(atomic_load(&context_starts[30])==1 && !atomic_load(&context_loops[30]));
    CHECK(atomic_load(&streams)==stream_base && atomic_load(&loops)==loop_base);
    CHECK(submit_pcm(cpu,voice,buffer,data,16,31,0x40,0));
    get_state(cpu,voice,state); CHECK(M32(state+4)==1 && M32(state+8)==0);
    CHECK(method(cpu,voice,19,2,zero)==0);
    CHECK(wait_count(&context_ends[31],1));
    get_state(cpu,voice,state); CHECK(M32(state+8)==16);
    CHECK(method(cpu,voice,20,2,zero)==0);

    /* StopEngine leaves queue notifications pending. More than MAX_QUEUE
     * flushes accumulated before restart must not overwrite earlier contexts.
     * 8256 records also cross the processing pass's 8192-event capacity. */
    CHECK(method(cpu,engine,12,0,NULL)==0);
    usleep(50000); /* let an already-entered pass finish; not a StopEngine fence test */
    unsigned end_base=atomic_load(&ends);
    for(unsigned n=0;n<8256;++n) {
        CHECK(submit_pcm(cpu,voice,buffer,data,16,300+n,0x40,2));
        CHECK(method(cpu,voice,22,0,NULL)==0);
    }
    get_state(cpu,voice,state);CHECK(M32(state+4)==0);
    usleep(30000);CHECK(atomic_load(&ends)==end_base);
    CHECK(method(cpu,engine,11,0,NULL)==0);
    CHECK(wait_count(&context_ends[8555],1));
    CHECK(atomic_load(&ends)==end_base+8256);
    for(unsigned n=0;n<8256;++n) {
        CHECK(atomic_load(&context_ends[300+n])==1);
        CHECK(!atomic_load(&context_starts[300+n]) && !atomic_load(&context_loops[300+n]));
        if(n) CHECK(atomic_load(&end_order[299+n])<atomic_load(&end_order[300+n]));
    }

    /* Starting a source while processing is paused does not make its first
     * queued buffer active. Flush removes it and leaves source Start intact. */
    CHECK(method(cpu,engine,12,0,NULL)==0);usleep(50000);
    CHECK(submit_pcm(cpu,voice,buffer,data,16,40,0x40,2));
    CHECK(method(cpu,voice,19,2,zero)==0);
    CHECK(method(cpu,voice,22,0,NULL)==0);
    get_state(cpu,voice,state);CHECK(M32(state+4)==0);
    CHECK(!atomic_load(&context_ends[40]));
    CHECK(submit_pcm(cpu,voice,buffer,data,16,41,0x40,0));
    CHECK(method(cpu,engine,11,0,NULL)==0);
    CHECK(wait_count(&context_ends[41],1));
    CHECK(atomic_load(&context_ends[40])==1 && !atomic_load(&context_starts[40]) && !atomic_load(&context_loops[40]));
    CHECK(atomic_load(&end_order[40])<atomic_load(&end_order[41]));
    CHECK(method(cpu,voice,20,2,zero)==0);

    /* A flushed end callback performs GetState, Submit, Flush, Submit on the
     * real guest COM voice, then the caller starts the last replacement. */
    reentrant_voice=voice;reentrant_state=gmalloc(16);reentrant_buffer=gmalloc(36);
    memset(GPTR(reentrant_buffer),0,36);
    M32(reentrant_buffer)=0x40;M32(reentrant_buffer+4)=32;M32(reentrant_buffer+8)=data;
    CHECK(submit_pcm(cpu,voice,buffer,data,16,200,0x40,2));
    CHECK(submit_pcm(cpu,voice,buffer,data,16,203,0x40,2));
    CHECK(method(cpu,voice,22,0,NULL)==0);
    CHECK(wait_count(&reentrant_result,1) && atomic_load(&reentrant_result)==1);
    CHECK(wait_count(&context_ends[201],1));
    CHECK(atomic_load(&context_ends[200])==1 && atomic_load(&context_ends[203])==1);
    CHECK(!atomic_load(&context_starts[200]) && !atomic_load(&context_starts[201]) && !atomic_load(&context_starts[203]));
    CHECK(atomic_load(&end_order[200])<atomic_load(&end_order[203]) && atomic_load(&end_order[203])<atomic_load(&end_order[201]));
    get_state(cpu,voice,state);CHECK(M32(state+4)==1 && M32(state)==202);
    CHECK(method(cpu,voice,19,2,zero)==0);
    CHECK(wait_count(&context_ends[202],1));
    CHECK(atomic_load(&context_starts[202])==1 && atomic_load(&context_ends[202])==1);
    CHECK(atomic_load(&wrong_callback_thread)==0 && atomic_load(&callback_thread)!=caller_thread);
    CHECK(method(cpu,voice,18,0,NULL)==0);
    return 0;
}

static int short_uncompressed_voice(CPU *cpu, uint32_t engine, uint32_t format,
                                    uint32_t data, uint32_t bytes, uint32_t expected_frames) {
    uint32_t output=gmalloc(4),args[]={output,format,0,0x40000000u,0,0,0};
    CHECK(method(cpu,engine,8,7,args)==0 && M32(output)!=0);
    uint32_t voice=M32(output),buffer=gmalloc(36),state=gmalloc(16);
    memset(GPTR(buffer),0,36);
    M32(buffer)=0x40;M32(buffer+4)=bytes;M32(buffer+8)=data;
    uint32_t submit[]={buffer,0},start[]={0,0};
    CHECK(method(cpu,voice,21,2,submit)==0);
    CHECK(method(cpu,voice,19,2,start)==0);
    CHECK(wait_finished(cpu,voice,state,2));
    CHECK(M32(state+8)==expected_frames);
    CHECK(method(cpu,voice,18,0,NULL)==0);
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr,"usage: audio_voice_probe MICROSOFT_WMAV2_FIXTURE\n"); return 2; }
    setenv("SDL_AUDIODRIVER", "dummy", 1);
    pthread_threadid_np(NULL,&caller_thread);
    g_log_level = 0;
    FILE *file = fopen(argv[1], "rb");
    CHECK(file != NULL);
    CHECK(fseek(file,0,SEEK_END) == 0);
    long length=ftell(file); rewind(file);
    CHECK(length >= 12 && length < 64 * 1024 * 1024);
    uint8_t *wave=malloc((size_t)length);
    CHECK(wave != NULL && fread(wave,1,(size_t)length,file)==(size_t)length);
    fclose(file);
    CHECK(!memcmp(wave,"RIFF",4) && !memcmp(wave+8,"XWMA",4));
    const uint8_t *fmt=NULL,*dpds=NULL,*data=NULL;
    uint32_t fmt_bytes=0,dpds_bytes=0,data_bytes=0;
    for(size_t offset=12;offset+8<=(size_t)length;) {
        uint32_t size=rd32(wave+offset+4);
        CHECK(offset+8ull+size<=(size_t)length);
        if(!memcmp(wave+offset,"fmt ",4)){fmt=wave+offset+8;fmt_bytes=size;}
        if(!memcmp(wave+offset,"dpds",4)){dpds=wave+offset+8;dpds_bytes=size;}
        if(!memcmp(wave+offset,"data",4)){data=wave+offset+8;data_bytes=size;}
        offset+=8ull+size+(size&1);
    }
    CHECK(fmt && fmt_bytes>=18 && dpds && dpds_bytes>=8 && data && data_bytes);
    CHECK(rd16(fmt)==0x161 && rd16(fmt+2)==1);

    MEM=mmap(NULL,1ull<<32,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS|MAP_NORESERVE,-1,0);
    CHECK(MEM!=MAP_FAILED && mprotect(MEM,0x10000,PROT_NONE)==0);
    rt_init_shims();
    CPU *cpu=rt_new_cpu(); rt_thread_init(cpu);
    uint32_t clsid=gmalloc(16),engine=0;
    static const uint8_t guid[16]={0x49,0x9b,0xda,0x3e,0x85,0x20,0x8b,0x49,0x9b,0xb2,0x39,0xa6,0x77,0x84,0x93,0xde};
    memcpy(GPTR(clsid),guid,sizeof guid);
    CHECK(xaudio2_create(clsid,&engine)!=0 && engine!=0);
    uint32_t master_out=gmalloc(4),master_args[]={master_out,2,48000,0,0,0};
    CHECK(method(cpu,engine,10,6,master_args)==0 && M32(master_out)!=0);
    uint32_t guest_fmt=gmalloc(fmt_bytes),guest_data=gmalloc(data_bytes),guest_dpds=gmalloc(dpds_bytes);
    memcpy(GPTR(guest_fmt),fmt,fmt_bytes);memcpy(GPTR(guest_data),data,data_bytes);memcpy(GPTR(guest_dpds),dpds,dpds_bytes);
    uint32_t callback=gmalloc(4),vtable=gmalloc(28);
    void (*callbacks[])(CPU*)={pass_start,pass_end,stream_end,buffer_start,buffer_end,loop_end,voice_error};
    for(unsigned n=0;n<7;++n) M32(vtable+4*n)=rt_thunk(callbacks[n],"authored-audio-callback");
    M32(callback)=vtable;
    uint32_t source_out=gmalloc(4),source_args[]={source_out,guest_fmt,0,0x40000000u,callback,0,0};
    CHECK(method(cpu,engine,8,7,source_args)==0 && M32(source_out)!=0);
    uint32_t voice=M32(source_out),buffer=gmalloc(36),packet_info=gmalloc(8),state=gmalloc(16);
    memset(GPTR(buffer),0,36);
    M32(buffer)=0x40;M32(buffer+4)=data_bytes;M32(buffer+8)=guest_data;
    M32(buffer+16)=512;M32(buffer+24)=512;M32(buffer+28)=2;M32(buffer+32)=0x513a;
    M32(packet_info)=guest_dpds;M32(packet_info+4)=dpds_bytes/4;
    uint32_t bad_submit[]={buffer,0};
    CHECK(method(cpu,voice,21,2,bad_submit)==0x88960001u);
    get_state(cpu,voice,state);CHECK(M32(state+4)==0);
    uint32_t submit[]={buffer,packet_info};
    CHECK(method(cpu,voice,21,2,submit)==0);
    get_state(cpu,voice,state);CHECK(M32(state+4)==1 && M32(state+8)==0);
    uint32_t start[]={0,0};
    CHECK(method(cpu,voice,19,2,start)==0);
    CHECK(wait_finished(cpu,voice,state,1));
    CHECK(atomic_load(&starts)==1 && atomic_load(&ends)==1 && atomic_load(&loops)==2 && atomic_load(&streams)==1);
    CHECK(atomic_load(&voice_errors)==0 && atomic_load(&passes)>0 && atomic_load(&nonzero_required)==0);
    CHECK(M32(state+8)==1536 && M32(state+12)==0);

    /* A second independently encoded stream reuses the same voice and decoder. */
    CHECK(method(cpu,voice,20,2,start)==0);
    M32(buffer)=0;M32(buffer+16)=256;M32(buffer+24)=0;M32(buffer+28)=0;
    CHECK(method(cpu,voice,21,2,submit)==0);
    CHECK(method(cpu,voice,23,0,NULL)==0); /* Discontinuity supplies EOS. */
    CHECK(method(cpu,voice,19,2,start)==0);
    CHECK(wait_finished(cpu,voice,state,2));
    CHECK(atomic_load(&starts)==2 && atomic_load(&ends)==2 && atomic_load(&streams)==2);
    CHECK(M32(state+8)==1792);

    /* Existing PCM16 and MS ADPCM voices still use their original paths. */
    uint32_t pcm_format=gmalloc(18),pcm_data=gmalloc(32);
    memset(GPTR(pcm_format),0,18);
    M16(pcm_format)=1;M16(pcm_format+2)=1;M32(pcm_format+4)=44100;
    M32(pcm_format+8)=88200;M16(pcm_format+12)=2;M16(pcm_format+14)=16;
    for(unsigned n=0;n<16;++n) M16(pcm_data+2*n)=n&1?0x4000:0xc000;
    CHECK(short_uncompressed_voice(cpu,engine,pcm_format,pcm_data,32,16)==0);
    uint32_t adpcm_format=gmalloc(26),adpcm_data=gmalloc(8);
    memset(GPTR(adpcm_format),0,26);memset(GPTR(adpcm_data),0,8);
    M16(adpcm_format)=2;M16(adpcm_format+2)=1;M32(adpcm_format+4)=44100;
    M32(adpcm_format+8)=88200;M16(adpcm_format+12)=8;M16(adpcm_format+14)=4;
    M16(adpcm_format+16)=8;M16(adpcm_format+18)=4;M16(adpcm_format+20)=1;
    M16(adpcm_format+22)=256;M16(adpcm_format+24)=0;
    M16(adpcm_data+1)=16;M16(adpcm_data+3)=1000;M16(adpcm_data+5)=0;M8(adpcm_data+7)=0x10;
    CHECK(short_uncompressed_voice(cpu,engine,adpcm_format,adpcm_data,8,4)==0);

    /* Honest unsupported-format error while the native decoder feature is on. */
    uint16_t previous=rd16(fmt);M16(guest_fmt)=0x9999;M32(source_out)=0x1234;
    CHECK(method(cpu,engine,8,7,source_args)==0x88960001u && M32(source_out)==0);
    M16(guest_fmt)=previous;

    CHECK(method(cpu,voice,20,2,start)==0);
    /* A failed compressed submission after stopped flush must leave SamplesPlayed
     * intact. Only a successful replacement resets it; flushing that decoded
     * replacement also exercises the WMA buffer's native allocation lifecycle. */
    CHECK(method(cpu,voice,22,0,NULL)==0);
    CHECK(method(cpu,voice,21,2,bad_submit)==0x88960001u);
    get_state(cpu,voice,state);CHECK(M32(state+4)==0 && M32(state+8)==1792);
    M32(buffer+32)=50;
    CHECK(method(cpu,voice,21,2,submit)==0);
    get_state(cpu,voice,state);CHECK(M32(state+4)==1 && M32(state+8)==0);
    CHECK(method(cpu,voice,22,0,NULL)==0);
    CHECK(wait_count(&context_ends[50],1) && !atomic_load(&context_starts[50]));
    CHECK(flush_regressions(cpu,engine,pcm_format,callback)==0);

    CHECK(method(cpu,engine,12,0,NULL)==0);
    CHECK(method(cpu,voice,18,0,NULL)==0);
    uint32_t master=M32(master_out);
    CHECK(method(cpu,master,18,0,NULL)==0);
    free(wave);
    printf("{\"pass\":true,\"scope\":\"real-XAudio2-COM-native-WMA-queue\",\"checks\":%u,"
        "\"buffer_starts\":%u,\"buffer_ends\":%u,\"loop_ends\":%u,\"stream_ends\":%u,"
        "\"decoded_samples_played\":1792,\"pcm16_samples_played\":16,\"adpcm_samples_played\":4,"
        "\"flush_accumulated_contexts\":8256,\"flush_reentrant\":true,\"callback_thread\":%llu,\"caller_thread\":%llu,"
        "\"audio_output\":\"SDL-dummy\",\"gameplay_tested\":false}\n",
        checks,atomic_load(&starts),atomic_load(&ends),atomic_load(&loops),atomic_load(&streams),
        (unsigned long long)atomic_load(&callback_thread),(unsigned long long)caller_thread);
    return 0;
}
