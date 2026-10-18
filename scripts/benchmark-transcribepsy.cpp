#include <parakeet/engine.h>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <sys/resource.h>
#include <sys/stat.h>
#include <vector>

using Clock = std::chrono::steady_clock;
static double seconds(Clock::time_point start) {
    return std::chrono::duration<double>(Clock::now() - start).count();
}
static std::string quoted(const std::string &value) {
    std::ostringstream out;
    out << '"';
    for (unsigned char ch : value) {
        if (ch == '"' || ch == '\\') out << '\\' << ch;
        else if (ch == '\n') out << "\\n";
        else if (ch >= 32) out << ch;
    }
    out << '"';
    return out.str();
}
static long peak_rss() {
    struct rusage usage{};
    getrusage(RUSAGE_SELF, &usage);
    return usage.ru_maxrss;
}

int main(int argc, char **argv) {
    if (argc != 6) {
        std::cerr << "usage: benchmark-transcribepsy MODEL AUDIO_DIR OUTPUT_DIR cpu|metal|coreml REPEATS\n";
        return 64;
    }
    try {
        const std::filesystem::path audio(argv[2]);
        const std::filesystem::path output(argv[3]);
        const std::string backend(argv[4]);
        std::filesystem::create_directories(output);
        parakeet::EngineOptions options;
        options.model_gguf_path = argv[1];
        options.n_threads = 8;
        options.n_gpu_layers = backend == "metal" ? 999 : 0;
        options.long_form_window_frames = 750;
        options.long_form_context_frames = 94;
        const auto load_start = Clock::now();
        parakeet::Engine engine(options);
        const double prepare_seconds = seconds(load_start);
        if (backend == "metal" && engine.backend_device() != parakeet::BackendDevice::GPU)
            throw std::runtime_error("GPU was requested but the engine fell back to CPU");
        if (backend == "coreml" && !engine.encoder_on_coreml())
            throw std::runtime_error("Core ML was requested but its encoder did not load");
        std::vector<std::string> rows;
        auto save = [&] {
            std::ofstream result(output / "result.json");
            result << std::setprecision(12)
                << "{\"label\":\"TranscribePsy " << backend << "\",\"model\":" << quoted(argv[1])
                << ",\"backend\":" << quoted(engine.backend_name())
                << ",\"encoderBackend\":" << quoted(engine.encoder_backend())
                << ",\"encoderOnCoreml\":" << (engine.encoder_on_coreml() ? "true" : "false")
                << ",\"prepareSeconds\":" << prepare_seconds
                << ",\"peakProcessRSSBytes\":" << peak_rss() << ",\"runs\":[";
            for (size_t index = 0; index < rows.size(); ++index) {
                if (index) result << ',';
                result << rows[index];
            }
            result << "]}\n";
        };
        for (int run = 1; run <= std::stoi(argv[5]); ++run) {
            auto started = Clock::now();
            double preprocess_ms = 0, encoder_ms = 0, decode_ms = 0, inference_ms = 0;
            std::string text;
            for (const char *track : {"system.wav", "mic.wav"}) {
                const auto result = engine.transcribe((audio / track).string());
                text += result.text + "\n";
                preprocess_ms += result.preprocess_ms;
                encoder_ms += result.encoder_ms;
                decode_ms += result.decode_ms;
                inference_ms += result.total_ms;
            }
            const auto run_seconds = seconds(started);
            if (text.find_first_not_of(" \n\r\t") == std::string::npos)
                throw std::runtime_error("TranscribePsy returned no speech");
            std::istringstream words(text);
            int word_count = 0;
            std::string word;
            while (words >> word) ++word_count;
            std::ostringstream row;
            row << std::setprecision(12) << "{\"run\":" << run << ",\"seconds\":" << run_seconds
                << ",\"preprocessMs\":" << preprocess_ms << ",\"encoderMs\":" << encoder_ms
                << ",\"decodeMs\":" << decode_ms << ",\"inferenceMs\":" << inference_ms
                << ",\"wordCount\":" << word_count << ",\"characterCount\":" << text.size() << '}';
            rows.push_back(row.str());
            const auto transcript = output / ("private-transcript-" + std::to_string(run) + ".txt");
            std::ofstream(transcript) << text;
            chmod(transcript.c_str(), 0600);
            save();
            std::cout << "TRANSCRIBEPSY " << backend << " run=" << run
                << " seconds=" << run_seconds << " words=" << word_count << std::endl;
        }
        const auto reference = engine.transcribe((audio / "reference.wav").string());
        std::ofstream(output / "reference.txt") << reference.text;
        save();
    } catch (const std::exception &error) {
        std::cerr << "BENCHMARK_ERROR: " << error.what() << '\n';
        return 1;
    }
}
