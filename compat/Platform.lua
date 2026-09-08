-- Android alone is not proof of a standalone Quest runtime.
local P={}
function P.standalone(osName,compat,host)
  return osName=='Android' and type(compat)=='table' and type(host)=='table'
    and type(compat.questVrInput)=='table' and host.questVrInput==compat.questVrInput
end
return P
