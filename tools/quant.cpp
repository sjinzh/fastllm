//
// Created by huangyuyang on 5/13/23.
//

#include <cstdio>
#include <cstring>
#include <iostream>

#include "moss.h"
#include "chatglm.h"
#include "vicuna.h"

struct QuantConfig {
    std::string model = "chatglm"; // 模型类型, chatglm或moss
    std::string path; // 模型文件路径
    std::string output; // 输出文件路径
    int bits; // 量化位数
};

void Usage() {
    std::cout << "Usage:" << std::endl;
    std::cout << "[-h|--help]:                      显示帮助" << std::endl;
    std::cout << "<-m|--model> <args>:              模型类型，默认为chatglm, 可以设置为chatglm, moss, vicuna" << std::endl;
    std::cout << "<-p|--path> <args>:               模型文件的路径" << std::endl;
    std::cout << "<-b|--bits> <args>:               量化位数, 4 = int4, 8 = int8, 16 = fp16" << std::endl;
    std::cout << "<-o|--output> <args>:             输出文件路径" << std::endl;
}

void ParseArgs(int argc, char **argv, QuantConfig &config) {
	std::vector <std::string> sargv;
	for (int i = 0; i < argc; i++) {
		sargv.push_back(std::string(argv[i]));
	}
	for (int i = 1; i < argc; i++) {
		if (sargv[i] == "-h" || sargv[i] == "--help") {
			Usage();
			exit(0);
		} else if (sargv[i] == "-m" || sargv[i] == "--model") {
			config.model = sargv[++i];
		} else if (sargv[i] == "-p" || sargv[i] == "--path") {
			config.path = sargv[++i];
		} else if (sargv[i] == "-b" || sargv[i] == "--bits") {
			config.bits = atoi(sargv[++i].c_str());
		} else if (sargv[i] == "-o" || sargv[i] == "--output") {
			config.output = sargv[++i];
		} else {
			Usage();
			exit(-1);
		}
	}
}

int main(int argc, char **argv) {
    QuantConfig config;
    ParseArgs(argc, argv, config);

    if (config.model == "moss") {
        fastllm::MOSSModel moss;
        moss.LoadFromFile(config.path);
        moss.SaveLowBitModel(config.output, config.bits);
    } else if (config.model == "chatglm") {
        fastllm::ChatGLMModel chatGlm;
        chatGlm.LoadFromFile(config.path);
        chatGlm.SaveLowBitModel(config.output, config.bits);
    } else if (config.model == "vicuna") {
        fastllm::VicunaModel vicuna;
        vicuna.LoadFromFile(config.path);
        vicuna.SaveLowBitModel(config.output, config.bits);
    } else {
        Usage();
        exit(-1);
    }

    return 0;
}