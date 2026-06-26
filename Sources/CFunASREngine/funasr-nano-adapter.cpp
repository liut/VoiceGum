// funasr-nano-adapter.cpp — C API bridge for FunASR-Nano
#include "funasr_engine.h"
#include "funasr-nano.h"

#define FUNASR_AUDIO_IMPLEMENTATION
#include "funasr_audio.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

// FBank computation (inline from CLI)
static const int FS=16000, WINLEN=400, SHIFT=160, NFFT=512, NMEL=80, LFR_M=7, LFR_N=6;
static const float PREEMPH=0.97f, LOWF=20.0f, HIGHF=8000.0f;

static inline float melf(float f){ return 1127.0f*logf(1.0f+f/700.0f); }

static void fftr(std::vector<float>&re,std::vector<float>&im,int n){
    for(int i=1,j=0;i<n;i++){int b=n>>1;for(;j&b;b>>=1)j^=b;j^=b;if(i<j){std::swap(re[i],re[j]);std::swap(im[i],im[j]);}}
    for(int len=2;len<=n;len<<=1){double a=-2.0*M_PI/len;float wr=cosf(a),wi=sinf(a);
        for(int i=0;i<n;i+=len){float cr=1,ci=0;for(int k=0;k<len/2;k++){
            float ur=re[i+k],ui=im[i+k];float vr=re[i+k+len/2]*cr-im[i+k+len/2]*ci,vi=re[i+k+len/2]*ci+im[i+k+len/2]*cr;
            re[i+k]=ur+vr;im[i+k]=ui+vi;re[i+k+len/2]=ur-vr;im[i+k+len/2]=ui-vi;
            float n2=cr*wr-ci*wi;ci=cr*wi+ci*wr;cr=n2;}}}
}

static std::vector<float> fbank_nano(std::vector<float> wav, int & T_out){
    for(auto&v:wav)v*=32768.0f;
    std::vector<float> win(WINLEN);
    for(int i=0;i<WINLEN;i++)win[i]=0.54f-0.46f*cosf(2.0f*M_PI*i/(WINLEN-1));
    const int NBIN=NFFT/2+1; float bw=(float)FS/NFFT,ml=melf(LOWF),mh=melf(HIGHF),dm=(mh-ml)/(NMEL+1);
    std::vector<std::vector<float>>fb(NMEL,std::vector<float>(NBIN,0.0f));
    for(int m=0;m<NMEL;m++){float L=ml+m*dm,C=ml+(m+1)*dm,R=ml+(m+2)*dm;
        for(int k=0;k<NBIN;k++){float mf=melf(bw*k);if(mf>L&&mf<R)fb[m][k]=mf<=C?(mf-L)/(C-L):(R-mf)/(R-C);}}
    int N=wav.size(); int T=(N-WINLEN)/SHIFT+1;
    std::vector<std::vector<float>>feat(T,std::vector<float>(NMEL));
    std::vector<float>re(NFFT),im(NFFT),fr(WINLEN); const float fl=1.1920929e-07f;
    for(int t=0;t<T;t++){const float*s=wav.data()+t*SHIFT;double mn=0;for(int i=0;i<WINLEN;i++)mn+=s[i];mn/=WINLEN;
        for(int i=0;i<WINLEN;i++)fr[i]=s[i]-(float)mn;for(int i=WINLEN-1;i>0;i--)fr[i]-=PREEMPH*fr[i-1];fr[0]-=PREEMPH*fr[0];
        for(int i=0;i<NFFT;i++){re[i]=i<WINLEN?fr[i]*win[i]:0.0f;im[i]=0.0f;}fftr(re,im,NFFT);
        for(int m=0;m<NMEL;m++){float e=0;for(int k=0;k<NBIN;k++)if(fb[m][k]>0)e+=fb[m][k]*(re[k]*re[k]+im[k]*im[k]);feat[t][m]=logf(e>fl?e:fl);}}
    const int pad=(LFR_M-1)/2; int Tl=(T+LFR_N-1)/LFR_N;
    std::vector<std::vector<float>>pd; pd.reserve(T+pad+LFR_M);
    for(int i=0;i<pad;i++)pd.push_back(feat[0]);for(int t=0;t<T;t++)pd.push_back(feat[t]);
    while((int)pd.size()<(Tl-1)*LFR_N+LFR_M)pd.push_back(feat[T-1]);
    int D=LFR_M*NMEL; std::vector<float> out((size_t)Tl*D);
    for(int i=0;i<Tl;i++)for(int j=0;j<LFR_M;j++)memcpy(&out[(size_t)i*D+j*NMEL],pd[i*LFR_N+j].data(),NMEL*sizeof(float));
    T_out=Tl; return out;
}

struct NanoHandle {
    NanoEncoderModel enc;
    NanoLLMContext llm;
    bool enc_loaded = false;
    bool llm_loaded = false;
};

extern "C" {

void * nano_load_model(const char * enc_gguf, const char * llm_gguf, int n_threads) {
    auto * h = new NanoHandle();
    if (!nano_encoder_load(enc_gguf, h->enc)) {
        fprintf(stderr, "[nano] failed to load encoder %s\n", enc_gguf);
        delete h; return nullptr;
    }
    h->enc_loaded = true;
    if (!nano_llm_load(llm_gguf, h->llm, n_threads > 0 ? n_threads : 8)) {
        fprintf(stderr, "[nano] failed to load LLM %s\n", llm_gguf);
        delete h; return nullptr;
    }
    h->llm_loaded = true;
    fprintf(stderr, "[nano] loaded encoder + LLM\n");
    return h;
}

void nano_free(void * handle) {
    if (!handle) return;
    auto * h = static_cast<NanoHandle *>(handle);
    if (h->llm_loaded) nano_llm_free(h->llm);
    if (h->enc.buf) ggml_backend_buffer_free(h->enc.buf);
    if (h->enc_loaded && h->enc.ctx_w) ggml_free(h->enc.ctx_w);
    delete h;
}

char * nano_transcribe(void * handle, const char * wav_path, int n_threads) {
    auto * h = static_cast<NanoHandle *>(handle);
    if (!h || !h->enc_loaded || !h->llm_loaded) return strdup("");

    // Load audio
    std::vector<float> wav;
    if (!funasr_load_audio_16k_mono(wav_path, wav)) {
        fprintf(stderr, "[nano] failed to load audio %s\n", wav_path);
        return strdup("");
    }

    // VAD-based speech segmentation
    int total_samples = (int)wav.size();
    auto segments = nano_vad_detect(wav, 16000);
    if (segments.empty()) {
        // Fallback: treat entire audio as one segment
        segments.push_back({0, total_samples});
    }

    const int max_chunk_samples = 30 * 16000;
    std::string full_text;

    for (auto & seg : segments) {
        // Split long segments into max 30s chunks
        for (int start = seg.start_sample; start < seg.end_sample; start += max_chunk_samples) {
            int end = start + max_chunk_samples;
            if (end > seg.end_sample) end = seg.end_sample;
            std::vector<float> seg_wav(wav.begin() + start, wav.begin() + end);

            int T = 0;
            auto fb = fbank_nano(seg_wav, T);
            if (T < 1) continue;

            int D_out = 0, n_aud = 0;
            auto audio_embd = nano_encoder_run(h->enc, fb, T, 560, D_out, n_aud);
            if (n_aud < 1) continue;

            auto text = nano_llm_transcribe(h->llm, audio_embd, n_aud, D_out);
            if (!text.empty()) full_text += text;
        }
    }

    return strdup(full_text.c_str());
}

} // extern "C"
