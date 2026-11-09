// PAGE XML renderer harness: decode the input as an image (any format Leptonica reads), OCR it with
// the Hebrew model, and render it through the public TessBaseAPI::GetPAGEText with polygons and word
// level on, which is the code path that builds the per-line left-to-right / right-to-left polygons.
#include <allheaders.h>
#include <tesseract/baseapi.h>

#include <libgen.h> // for dirname
#include <cstdio>   // for printf
#include <cstdlib>  // for std::getenv, std::setenv
#include <string>   // for std::string

static tesseract::TessBaseAPI *api = nullptr;

extern "C" int LLVMFuzzerInitialize(int * /*pArgc*/, char ***pArgv) {
  if (std::getenv("TESSDATA_PREFIX") == nullptr) {
    std::string binary_path = *pArgv[0];
    const std::string filepath = dirname(&binary_path[0]);

    const std::string tessdata_path = filepath + "/" + "tessdata";
    if (setenv("TESSDATA_PREFIX", tessdata_path.c_str(), 1) != 0) {
      printf("Setenv failed\n");
      std::abort();
    }
  }

  api = new tesseract::TessBaseAPI();
  if (api->Init(nullptr, "heb") != 0) {
    printf("Cannot initialize API\n");
    abort();
  }

  /* Silence output */
  api->SetVariable("debug_file", "/dev/null");
  api->SetVariable("page_xml_polygon", "1");
  api->SetVariable("page_xml_level", "1");

  return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  Pix *pix = pixReadMem(data, size);
  if (pix == nullptr) {
    return -1; // not an image
  }

  api->SetImage(pix);
  char *page = api->GetPAGEText(0);
  pixDestroy(&pix);
  delete[] page;

  // Nothing of this input may leak into the next one.
  api->Clear();
  api->ClearAdaptiveClassifier();

  return 0;
}
