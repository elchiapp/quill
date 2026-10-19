// Supplemental current-upstream C++ API lanes. Input TSV contains public PCM paths only.
#include <parakeet/engine.h>
#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <sys/resource.h>
#include <vector>

using Clock = std::chrono::steady_clock;
static double seconds(Clock::time_point start) { return std::chrono::duration<double>(Clock::now()-start).count(); }
static std::string json(const std::string& text) {
    std::ostringstream out; out << '"';
    for (unsigned char c : text) {
        if (c == '"' || c == '\\') out << '\\' << c;
        else if (c == '\n') out << "\\n";
        else if (c >= 32) out << c;
    }
    out << '"'; return out.str();
}
struct Sample { std::string id, path; double duration; };
static std::vector<float> read_pcm(const std::string& path) {
    std::ifstream file(path, std::ios::binary);
    if (!file) throw std::runtime_error("Cannot open PCM fixture");
    std::vector<char> bytes((std::istreambuf_iterator<char>(file)), {});
    if (bytes.size()%2) throw std::runtime_error("Incomplete PCM frame");
    std::vector<float> samples(bytes.size()/2);
    for (size_t i=0; i<samples.size(); ++i) {
        auto value=static_cast<int16_t>(static_cast<unsigned char>(bytes[i*2]) | (static_cast<unsigned char>(bytes[i*2+1])<<8));
        samples[i]=value/32768.0f;
    }
    return samples;
}
int main(int argc,char**argv) {
    if (argc!=7) { std::cerr<<"MODEL TSV OUTPUT cpu|metal|coreml REPEATS LABEL\n"; return 64; }
    try {
        const std::string compute=argv[4];
        if(compute=="coreml")unsetenv("PARAKEET_COREML_DISABLE");else setenv("PARAKEET_COREML_DISABLE","1",1);
        setenv("PARAKEET_COREML_COMPUTE_UNITS","cpu_and_ane",1);
        parakeet::EngineOptions options; options.model_gguf_path=argv[1]; options.n_threads=8;
        options.n_gpu_layers=compute=="metal"?999:0;
        auto load=Clock::now(); parakeet::Engine engine(options); double prepare=seconds(load);
        if (compute=="metal" && engine.backend_device()!=parakeet::BackendDevice::GPU) throw std::runtime_error("Metal fell back to CPU");
        if (compute=="coreml" && !engine.encoder_on_coreml()) throw std::runtime_error("Core ML encoder did not load");
        std::ifstream list(argv[2]); std::string line; std::vector<Sample> samples;
        while (std::getline(list,line)) { std::istringstream row(line); Sample s; std::string duration;
            std::getline(row,s.id,'\t'); std::getline(row,s.path,'\t'); std::getline(row,duration); s.duration=std::stod(duration); samples.push_back(s); }
        if(samples.empty()) throw std::runtime_error("Empty matrix");
        const auto warm=read_pcm(samples[0].path); auto warmStart=Clock::now(); engine.transcribe_samples(warm.data(),int(warm.size()),16000); double warmup=seconds(warmStart);
        std::vector<std::string> rows;
        auto save=[&] { struct rusage usage{}; getrusage(RUSAGE_SELF,&usage);
            std::ofstream out(argv[3]); out.precision(12);
            out<<"{\"label\":"<<json(argv[6])<<",\"prepareSeconds\":"<<prepare<<",\"warmupSeconds\":"<<warmup
               <<",\"backend\":"<<json(engine.backend_name())<<",\"encoderBackend\":"<<json(engine.encoder_backend())
               <<",\"encoderOnCoreml\":"<<(engine.encoder_on_coreml()?"true":"false")<<",\"npuHardwareVerified\":false"
#ifdef TRACK_ACTUAL_COREML
               <<",\"coremlActualFlagSupported\":true"
#else
               <<",\"coremlActualFlagSupported\":false"
#endif
               <<",\"peakEngineRSSBytes\":"<<usage.ru_maxrss<<",\"cpuSeconds\":"<<(usage.ru_utime.tv_sec+usage.ru_utime.tv_usec/1e6+usage.ru_stime.tv_sec+usage.ru_stime.tv_usec/1e6)<<",\"runs\":[";
            for(size_t i=0;i<rows.size();++i){if(i)out<<',';out<<rows[i];} out<<"]}"; };
        for(int run=1;run<=std::stoi(argv[5]);++run) for(const auto&s:samples) {
            if(s.duration>300&&run>1)continue;
            auto pcm=read_pcm(s.path); auto start=Clock::now(); std::string text,error; double encoder=0,decoder=0,preprocess=0; int coremlCalls=0, calls=0;
            try { for(size_t offset=0;offset<pcm.size();offset+=960000) {
                const size_t size=std::min<size_t>(960000,pcm.size()-offset);
                if(std::all_of(pcm.begin()+offset,pcm.begin()+offset+size,[](float x){return x==0;}))continue;
                const auto result=engine.transcribe_samples(pcm.data()+offset,int(size),16000);
                text+=(text.empty()?"":" ")+result.text; encoder+=result.encoder_ms; decoder+=result.decode_ms; preprocess+=result.preprocess_ms; ++calls;
#ifdef TRACK_ACTUAL_COREML
                coremlCalls+=result.encoder_used_coreml?1:0;
#endif
            }}catch(const std::exception&e){error=e.what();}
            std::ostringstream row; row.precision(12);
            row<<"{\"sampleID\":"<<json(s.id)<<",\"run\":"<<run<<",\"durationSeconds\":"<<s.duration<<",\"seconds\":"<<seconds(start)
               <<",\"text\":"<<json(text)<<",\"encoderMs\":"<<encoder<<",\"decoderMs\":"<<decoder<<",\"preprocessMs\":"<<preprocess
               <<",\"calls\":"<<calls<<",\"coremlCalls\":"<<coremlCalls;
            if(!error.empty())row<<",\"error\":"<<json(error); row<<'}'; rows.push_back(row.str()); save();
            std::cout<<argv[6]<<": "<<s.id<<" run="<<run<<" done\n"<<std::flush;
        }
    }catch(const std::exception&e){std::cerr<<e.what()<<'\n';return 1;}
}
