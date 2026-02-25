#include <tgcalls/Instance.h>
#include <tgcalls/InstanceImpl.h>
#include <tgcalls/v2/InstanceV2Impl.h>

extern "C" bool froth_tgcalls_register() {
  bool registered = false;

  registered = tgcalls::Register<tgcalls::InstanceImpl>() || registered;
  registered = tgcalls::Register<tgcalls::InstanceV2Impl>() || registered;

  return registered;
}
