extends Node

#EthersWeb.window.walletBridge

##########   ENCODING   #########

# Ethers.js encodes the elementary types
func _js_abi_encode(_types, _values):
	var types = EthersWeb.arr_to_obj(_types)
	var values = EthersWeb.arr_to_obj(_values)
	var calldata = EthersWeb.window.walletBridge.abiEncode(types, values)
	return calldata.substr(2)

# Keccak hash the formatted selector string
# The returned hash will start with "0x"
func _js_get_function_selector(selector_string):
	
	var selector_hash = EthersWeb.window.walletBridge.getFunctionSelector(selector_string)
	return selector_hash.left(10)

# Ethers.js decodes the elementary types
func _js_abi_decode(_types, calldata):
	var types = EthersWeb.arr_to_obj(_types)
	if !calldata.begins_with("0x"):
		calldata = "0x" + calldata
	var values = EthersWeb.window.walletBridge.abiDecode(types, calldata)
	return values


func get_function_calldata(abi, function_name, _args=[]):
	var args = []
	var calldata = ""
	
	var function = get_function(abi, function_name)
	if !function:
		return false
		
	var inputs = get_function_inputs(function)
	
	if inputs:
		calldata = abi_encode(inputs, _args)
		
		
	var function_selector = get_function_selector(function)
	
	return function_selector + calldata
	

func get_function(abi, function_name):
	for function in abi:
		if function.has("name"):
			if function["name"] == function_name:
				return function
	return false


func get_function_inputs(function):
	if function.has("inputs"):
		return(function["inputs"])
	return false


# NOTE
# inputs is an array of dictionaries each containing a "type" field,
# and a "components" field if the type is a tuple
func abi_encode(inputs, _args):
	var args = []
	var selector = 0
	for input in inputs:
						
		var new_arg = {
			"value": _args[selector],
			"type": input["type"],
			"calldata": "",
			"length": 0,
			"dynamic": false
			}
				
		if input["type"].contains("tuple"):
			new_arg["components"] = input["components"]
		args.push_back(new_arg)
		selector += 1
	
	var calldata = construct_calldata(args)
	return calldata
	

func construct_calldata(args):
	var body = []
	var tail = []
	var calldata = ""
	var callback_index = 0
	
	# Determines which types are dynamic.  If the type
	# is dynamic, inserts a placeholder uint256 into
	# the body of the calldata.  It will be updated 
	# later after the offset can be calculated.
	for arg in args:
		var arg_type = arg["type"]
		if arg_type.contains("["):
			if array_is_dynamic(arg_type):
				arg["dynamic"] = true
		elif arg_type.begins_with("bytes"):
			if arg_type.length() == 5:
				arg["dynamic"] = true
		elif arg_type.begins_with("tuple"):
			if tuple_is_dynamic(arg):
				arg["dynamic"] = true
		elif arg_type.begins_with("string"):
				arg["dynamic"] = true
				
		if arg["dynamic"]:
			var placeholder = {
				"value": "placeholder",
				"type": "uint256",
				"calldata": "placeholder",
				"length": 32,
				"dynamic": false
			}
			body.push_back(placeholder)
			arg["callback_index"] = callback_index
			
			# Save dynamic args in the tail, to be encoded 
			# after static args have been encoded.
			tail.push_back(arg)
			
		else:
			
			# Static args go straight into the body, so that 
			# they are encoded first.
			body.push_back(arg)
			
		callback_index += 1
	
	# Merge the body and tail arrays.
	body.append_array(tail)
	
	# The args are encoded in sequence, starting with the static args.
	# The length of each argument is recorded as it is encoded.
	# These lengths are then used to calculate the offsets
	# for the dynamic args.
	var selector = 0
	for chunk in body:
		if chunk["calldata"] != "placeholder":
			chunk["calldata"] = encode_arg(chunk)
			chunk["length"] = chunk["calldata"].length() / 2
			if chunk["dynamic"]:
				var _callback_index = chunk["callback_index"]
				var total_offset = 0
				for _chunk in range(selector):
					var _length = body[_chunk]["length"]
					total_offset += _length
				body[_callback_index]["value"] = total_offset
				body[_callback_index]["calldata"] = _js_abi_encode(["uint256"], [str(total_offset)])
			
		selector += 1
	
	# Concatenate the calldata chunks.
	for _calldata in body:
		calldata += _calldata["calldata"]
	
	return calldata


func encode_arg(arg):
	var calldata = ""
	
	var arg_type = arg["type"]
	var arg_value = arg["value"]
	
	# Array
	if arg_type.contains("["):
		calldata = encode_array(arg)
	
	# Tuple
	elif arg_type.begins_with("tuple"):
		calldata = encode_tuple(arg)
	
	# String, Bytes
	elif arg_type in ["string", "bytes"]:
		# Checks if the bytes have been provided as a 
		# PackedByteArray, and converts to a hex String.
		if arg_type == "bytes":
			if typeof(arg_value) == 29:
				arg_value = arg_value.hex_encode()
	
		if !arg_value.begins_with("0x"):
			arg_value = "0x" + arg_value
		calldata = _js_abi_encode([arg_type], [arg_value])
		
		# Remove filler offset added by Ethers-js
		calldata = calldata.trim_prefix("0000000000000000000000000000000000000000000000000000000000000020")
	
	# Fixed Bytes
	elif arg_type.begins_with("bytes"):
		calldata = encode_fixed_bytes(arg)
	
	# Enum
	elif arg_type == "enum":
		calldata = _js_abi_encode(["uint8"], [arg_value])
	
	# Uint, Int, Address, Bool
	else:
		#Checks if type is bool and if it has been given as a string
		if arg_type == "bool":
			if typeof(arg_value) == 4:
				if arg_value == "true":
					arg_value = true
				else:
					arg_value = false
				
		calldata = _js_abi_encode([arg_type], [arg_value])
	
	return calldata


func get_function_selector(function):
	var selector_string = function["name"] + "("
	var index = 0
	for input in function["inputs"]:
		index += 1
		if input["type"].contains("tuple"):
			selector_string += get_tuple_components(input)
			if index == function["inputs"].size():
				selector_string = selector_string.trim_suffix(",")
			if input["type"].length() > 5:
				selector_string = selector_string.trim_suffix(",")
				selector_string += input["type"].right(-5)
				selector_string += ","
		else:
			selector_string += input["type"] + ","
			
	selector_string = selector_string.trim_suffix(",") + ")"
	#var selector_bytes = selector_string.to_utf8_buffer()
	var function_selector = _js_get_function_selector(selector_string)
	#var function_selector = GodotSigner.get_function_selector(selector_bytes).left(8)
	return function_selector


func get_tuple_components(input):	
	var selector_string = ""
	
	for component in input["components"]:
		if component["type"].contains("tuple"):
			selector_string += get_tuple_components(component)
			if component["type"].length() > 5:
				selector_string = selector_string.trim_suffix(",")
				selector_string += component["type"].right(-5)
				selector_string += ","
		else:
			selector_string += component["type"] + ","
	
	selector_string = selector_string.trim_suffix(",")
	return ("(" + selector_string + "),")


func array_is_dynamic(arg_type):
	for dynamic_type in ["string", "bytes"]:
		if arg_type.begins_with(dynamic_type):
			return true
	
	if arg_type.contains("[]"):
		return true
		
	return false


func tuple_is_dynamic(arg):
	var components = arg["components"]
	for component in components:
		var arg_type = component["type"]
		if arg_type.contains("["):
			if array_is_dynamic(arg_type):
				return true
		elif arg_type.begins_with("bytes"):
			if arg_type.length() == 5:
				return true
		elif arg_type.begins_with("tuple"):
			if tuple_is_dynamic(arg_type):
				return true
		elif arg_type.begins_with("string"):
				return true
	
	return false


func encode_fixed_bytes(arg):
	var value = arg["value"]
	var arg_type = arg["type"]
		
	# Checks if the bytes have been provided as a PackedByteArray,
	# and converts into a hex String
	if typeof(value) == 29:
		value = value.hex_encode()
	
	while value.length() < 64:
		value += "0"
	
	if !value.begins_with("0x"):
		value = "0x" + value
	return value


func encode_array(arg):
	
	var _arg_type = arg["type"]
	var value_array = arg["value"]
	
	# Nested Arrays are encoded right to left
	var type_splitter = 2
	var array_checker = _arg_type.right(type_splitter)
	
	# Check if the rightmost array has a fixed size
	if array_checker.contains("[]"):
		arg["fixed_size"] = false
	else:
		arg["fixed_size"] = true
		type_splitter += 1
	
	# Extract the type of the rightmost array's elements
	var arg_type = _arg_type.left(-type_splitter)
	
	var calldata = ""
	var args = []
	
	for value in value_array:
	
		var new_arg = {
			"value": value,
			"type": arg_type,
			"calldata": "",
			"length": 0,
			"dynamic": false
			}
		if arg_type.contains("tuple"):
			new_arg["components"] = arg["components"]
		args.push_back(new_arg)
	
	calldata = construct_calldata(args)
	
	# Add length component if unfixed size
	if !arg["fixed_size"]:
		var _param_count = str(arg["value"].size())
		var param_count = _js_abi_encode(["uint256"], [_param_count])
		calldata = param_count + calldata
		
	return calldata


func encode_tuple(arg):
	var value_array = arg["value"]
	var components = arg["components"]

	var args = []
	var selector = 0
	for component in components:
		var new_arg = {
			"value": value_array[selector],
			"type": component["type"],
			"calldata": "",
			"length": 0,
			"dynamic": false
				}
		if component["type"].contains("tuple"):
			new_arg["components"] = component["components"]
		args.push_back(new_arg)
		selector += 1

	var calldata = construct_calldata(args)
	
	return calldata
	





##########   DECODING   #########


# NOTE: 
# Use get_function(abi, function_name) to get the function object, 
# then pass the function object to get_function_outputs(function).
func get_function_outputs(function):
	if function.has("outputs"):
		return(function["outputs"])
	return false


#NOTE:
# _outputs is an array of dictionaries each containing a "type" field,
# and a "components" field if the type is a tuple
func abi_decode(_outputs, calldata):
	#print(_outputs, calldata)
	calldata = calldata.trim_prefix("0x")
	
	var outputs = []
	for output in _outputs:

		var new_output = {
			"type" = output["type"],
			"dynamic" = false,
		}
		if output["type"].contains("tuple"):
			new_output["components"] = output["components"]
		outputs.push_back(new_output)

	var decoded = deconstruct_calldata(outputs, calldata)

	return decoded
	

func deconstruct_calldata(outputs, calldata):
	
	var decoded_values = []
	var dynamic_outputs = []
		
	# Determine which types are dynamic.
	for output in outputs:
		var output_type = output["type"]
		if output_type.contains("["):
			if array_is_dynamic(output_type):
				output["dynamic"] = true
		elif output_type.begins_with("bytes"):
			if output_type.length() == 5:
				output["dynamic"] = true
		elif output_type.begins_with("tuple"):
			if tuple_is_dynamic(output):
				output["dynamic"] = true
		elif output_type.begins_with("string"):
				output["dynamic"] = true
	
	# Fill in decoded static values and placeholders
	# for dynamic values.  Track the current position
	# in the calldata after decoding each value.
	var position = 0
	var head_index = 0
	for output in outputs:
		if output["dynamic"]:
			# Decode the offset value and obtain the 
			# placeholder's index.
			var _offset = calldata.substr(position, 64)
			position += 64
			var offset = _js_abi_decode(["uint256"], _offset)
			output["offset"] = offset
			output["head_index"] = head_index
			dynamic_outputs.push_back(output)
			decoded_values.push_back("")
		else:
			# Because static args have a fixed size, it's possible to
			# know their length immediately. All single args take up 32 bytes.
			# Static arrays and tuples take up multiples of 32 bytes.
			var arg_length = get_static_size(output) * 2
			
			# Decode the static arg using a substring sliced using
			# the arg length.  Track the current position in the 
			# calldata by adding the length.
			var _calldata = calldata.substr(position, arg_length)
			
			position += arg_length
			
			var decode_result = decode_arg(output, _calldata)
			decoded_values.push_back(decode_result)
		
		head_index += 1
	
	var dynamic_selector = 0
	for output in dynamic_outputs:
		var start_position = int(output["offset"]) * 2
		var end_position
		if dynamic_selector == dynamic_outputs.size() - 1:
			end_position = calldata.length()
		else:
			dynamic_selector += 1
			var next_offset = dynamic_outputs[dynamic_selector]
			end_position = int(next_offset["offset"]) * 2
		
		var length = end_position - start_position
		var _calldata = calldata.substr(start_position, length)
		var decode_result = decode_arg(output, _calldata)
		var _head_index = output["head_index"]
		decoded_values[_head_index] = decode_result
	
	return decoded_values
	

# Замість вашої поточної get_static_size, використайте:

func get_static_size(output):
	var arg_type = output["type"]

	# ——— Статичні масиви ———
	if arg_type.find("[") != -1 and not arg_type.ends_with("[]"):
		# витягнути число між “[” та “]”
		var start = arg_type.find("[") + 1
		var end   = arg_type.find("]")
		var len_str = arg_type.substr(start, end - start)
		var count = int(len_str)

		# елемент — все, що ліворуч від “[”
		var elem_type = arg_type.substr(0, start - 1)
		var inner = {"type": elem_type}
		if output.has("components"):
			inner["components"] = output["components"]

		# кожен елемент займає get_static_size(inner) байт
		return count * get_static_size(inner)

	# ——— Тьюпли ———
	elif arg_type.begins_with("tuple"):
		var total = 0
		for comp in output["components"]:
			total += get_static_size(comp)
		return total

	# ——— Все інше ———
	else:
		return 32



func decode_arg(arg, calldata):
	var t = arg["type"]
	#print("--> decode_arg, type =", t)
	if t.find("[") != -1:
		#print("    ⤷ виявлено масив, йдемо в decode_array")
		return decode_array(arg, calldata)
	elif t.begins_with("tuple"):
		return abi_decode(arg["components"], calldata)
	elif t in ["string","bytes"]:
		var s = calldata.begins_with("0x") if calldata else ("0x" + calldata)
		return _js_abi_decode([t], s)
		# …твій існуючий код для string/bytes…
	elif t.begins_with("bytes"):
		return decode_fixed_bytes(calldata, t)
	elif t == "enum":
		return _js_abi_decode(["uint8"], calldata)
	else:
		var v = _js_abi_decode([t], calldata)
		if t == "bool":
			return (v == "true")
		return v
	


	

func decode_fixed_bytes(bytes, _bytes_amount):
	var bytes_amount = int(_bytes_amount.trim_prefix("bytes"))
	var zero_count = 32 - bytes_amount
	for zero in range(zero_count):
		bytes = bytes.trim_suffix("0")

	return bytes


func decode_array(arg, calldata):
	#print("    -> decode_array, raw calldata:", calldata)
	var type_str = arg["type"]
	var is_dyn = type_str.ends_with("[]")
	var count = 0
	var offset = 0
	# для динамічних масивів перші 32 байти — довжина
	if is_dyn:
		var len_chunk = calldata.substr(0, 64)
		count = int(_js_abi_decode(["uint256"], len_chunk))
		offset = 64
	else:
		# витягуємо число між [ та ]
		var b = type_str.find("[") + 1
		var e = type_str.find("]")
		count = int(type_str.substr(b, e - b))
		offset = 0
	# тип елемента до “[”
	var elem_type = type_str.substr(0, type_str.find("["))
	var result = []
	# кожен елемент — 32 байти = 64 hex-символи
	for i in range(count):
		var start = offset + i * 64
		var chunk = calldata.substr(start, 64)
		result.append(_js_abi_decode([elem_type], chunk))
	return result
