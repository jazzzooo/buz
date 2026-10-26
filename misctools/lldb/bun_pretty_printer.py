# Pretty printers for Bun data structures
import lldb
import codecs
import json

class bun_BabyList_SynthProvider:
    def __init__(self, value, _=None): 
        self.value = value
        
    def update(self):

        try:
            self.ptr = self.value.GetChildMemberWithName('ptr')
            self.len = self.value.GetChildMemberWithName('len').GetValueAsUnsigned()
            self.cap = self.value.GetChildMemberWithName('cap').GetValueAsUnsigned()
            self.elem_type = self.ptr.type.GetPointeeType()
            self.elem_size = self.elem_type.size
        except:
            self.len = 0
            self.cap = 0
            pass

            
    def has_children(self): 
        return True
        
    def num_children(self): 
        return self.len or 0
        
    def get_child_index(self, name):
        try: 
            return int(name.removeprefix('[').removesuffix(']'))
        except: 
            return -1
            
    def get_child_at_index(self, index):
        if index not in range(self.len): 
            return None
        try: 
            return self.ptr.CreateChildAtOffset('[%d]' % index, index * self.elem_size, self.elem_type)
        except: 
            return None

def bun_BabyList_SummaryProvider(value, _=None):
    try:
        # Get the non-synthetic value to access raw members
        value = value.GetNonSyntheticValue()
        len_val = value.GetChildMemberWithName('len')
        cap_val = value.GetChildMemberWithName('cap')
        return 'len=%d cap=%d' % (len_val.GetValueAsUnsigned(), cap_val.GetValueAsUnsigned())
    except:
        return 'len=? cap=?'

def add(debugger, *, category, regex=False, type, identifier=None, synth=False, inline_children=False, expand=False, summary=False):
    prefix = '.'.join((__name__, (identifier or type).replace('.', '_').replace(':', '_')))
    if summary: 
        debugger.HandleCommand('type summary add --category %s%s%s "%s"' % (
            category, 
            ' --inline-children' if inline_children else ''.join((' --expand' if expand else '', ' --python-function %s_SummaryProvider' % prefix if summary == True else ' --summary-string "%s"' % summary)), 
            ' --regex' if regex else '', 
            type
        ))
    if synth: 
        debugger.HandleCommand('type synthetic add --category %s%s --python-class %s_SynthProvider "%s"' % (
            category, 
            ' --regex' if regex else '', 
            prefix, 
            type
        ))

def _unsigned(value):
    error = lldb.SBError()
    result = value.GetValueAsUnsigned(error)
    if error.Fail():
        raise ValueError(error.GetCString())
    return result


def _read_unsigned(process, address, size):
    error = lldb.SBError()
    result = process.ReadUnsignedFromMemory(address, size, error)
    if error.Fail():
        raise ValueError(error.GetCString())
    return result


def _string_layout_constant(target, name):
    symbol_name = 'Bun__WTFStringImpl__' + name
    symbols = target.FindSymbols(symbol_name)
    for index in range(symbols.GetSize()):
        symbol = symbols.GetContextAtIndex(index).GetSymbol()
        address = symbol.GetStartAddress().GetLoadAddress(target)
        if address != lldb.LLDB_INVALID_ADDRESS:
            return _read_unsigned(target.GetProcess(), address, 4)
    raise ValueError('unavailable string layout symbol: ' + symbol_name)


def WTFStringImpl_SummaryProvider(value, _=None):
    try:
        value = value.GetNonSyntheticValue()
        pointer = value if value.GetType().IsPointerType() else value.AddressOf()
        address = _unsigned(pointer)
        if address == 0:
            return '<null string>'

        target = value.GetTarget()
        process = value.GetProcess()
        # Zig's handle is opaque; the engine exports the layout for this target.
        length = _read_unsigned(process, address + _string_layout_constant(target, 'lengthOffset'), 4)
        flags = _read_unsigned(process, address + _string_layout_constant(target, 'flagsOffset'), 4)
        is_8bit = bool(flags & _string_layout_constant(target, 'flagIs8Bit'))
        encoding = 'latin1' if is_8bit else 'utf16'
        if length == 0:
            return '[%s] ""' % encoding

        data = _read_unsigned(process, address + _string_layout_constant(target, 'dataOffset'), target.GetAddressByteSize())
        if data == 0:
            raise ValueError('nonempty string has a null data pointer')

        max_characters = 200
        unit_size = 1 if is_8bit else 2
        # A displayed Unicode character can occupy two UTF-16 code units.
        units = min(length, (max_characters + 1) * unit_size)
        error = lldb.SBError()
        raw = process.ReadMemory(data, units * unit_size, error)
        if error.Fail():
            raise ValueError(error.GetCString())
        if len(raw) != units * unit_size:
            raise ValueError('incomplete string memory read')

        if is_8bit:
            text = raw.decode('latin1')
        else:
            byte_order = target.GetByteOrder()
            if byte_order == lldb.eByteOrderLittle:
                codec = 'utf-16le'
            elif byte_order == lldb.eByteOrderBig:
                codec = 'utf-16be'
            else:
                raise ValueError('unknown target byte order')
            decoder = codecs.getincrementaldecoder(codec)(errors='backslashreplace')
            text = decoder.decode(raw, final=units == length)

        truncated = units < length or len(text) > max_characters
        display = json.dumps(text[:max_characters], ensure_ascii=False)
        if truncated:
            return '[%s length=%d] %s <truncated>' % (encoding, length, display)
        return '[%s] %s' % (encoding, display)
    except Exception as error:
        return '<string unavailable: %s>' % error


def bun_String_SummaryProvider(value, _=None):
    try:
        value = value.GetNonSyntheticValue()
        tag = _unsigned(value.GetChildMemberWithName('tag'))
        if tag == 0:
            return '<dead>'
        if tag == 4:
            return '""'
        if tag != 1:
            return '<unknown string tag %d>' % tag

        impl = value.GetChildMemberWithName('value').GetChildMemberWithName('WTFStringImpl')
        if not impl.IsValid():
            raise ValueError('missing string implementation handle')
        return WTFStringImpl_SummaryProvider(impl)
    except Exception as error:
        return '<string unavailable: %s>' % error


def __lldb_init_module(debugger, _=None):
    debugger.HandleCommand('type category define --language c99 bun')
    add(debugger, category='bun', regex=True, type=r'^baby_list\.BabyList\(.*\)$', identifier='bun_BabyList', synth=True, expand=True, summary=True)
    add(debugger, category='bun', regex=True, type=r'^\*?(const )?((string\.)?wtf\.|string\.)?WTFStringImpl(Struct)?$', identifier='WTFStringImpl', summary=True)
    for type_name in ('string.string.String', 'string.String', 'bun.String'):
        add(debugger, category='bun', type=type_name, identifier='bun_String', summary=True)
    debugger.HandleCommand('type category enable bun')
