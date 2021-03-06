library json_mapper_v1;

import "dart:json";

import 'package:portable_mirror/mirror_api_lib.dart';

part 'src/dart_JsonStringifier.dart'; // this should be eliminated, dart:json should have pblic class JsonStringifier instead of _JsonStringifier

typedef dynamic ConstructorFun(Map map);
typedef dynamic StringifierFun(Object obj);
typedef dynamic ConvertFun(Object obj);

abstract class ISpecialTypeMapHandler {
  ConstructorFun entityCtor(Type type);
  StringifierFun stringifier(Type type);
  ConvertFun convert(Type type);
}

class SpecialTypeMapHandler implements ISpecialTypeMapHandler {
  final Map<Type, ConstructorFun> entityCtors;
  final Map<Type, ConvertFun> _converts = {DateTime: (Object value)=>DateTime.parse(value)};
  final Map<Type, StringifierFun> _stringifiers = {DateTime: (DateTime dt) => '"${dt.toString()}"'};
  
  SpecialTypeMapHandler(this.entityCtors, {Map<Type, ConvertFun> converts, Map<Type, StringifierFun> stringifiers}) {
    if (converts != null) _converts.addAll(converts);
    if (stringifiers != null) _stringifiers.addAll(stringifiers);
  }
  
  ConstructorFun entityCtor(Type type)=>(entityCtors == null)?null:entityCtors[type];
  ConvertFun convert(Type type)=>_converts[type];
  StringifierFun stringifier(Type type)=>_stringifiers[type];
}

//
//
//
abstract class IJsonMapper {
  Object fromJson(Type modelType, String json);
  
  String toJson(final object, {StringSink output});
}

class JsonMapper implements IJsonMapper {
  EntityJsonParser parser;
  EntityJsonStringifier stringifier;
  ISpecialTypeMapHandler mapHandler;
  
  JsonMapper(this.mapHandler, {_Reviver reviver}) {
    parser = new EntityJsonParser(mapHandler, reviver: reviver);
    stringifier = new EntityJsonStringifier(mapHandler);
  }

  Object fromJson(Type modelType, String json) => parser.parse(modelType, json);
  String toJson(final object, {StringSink output}) => stringifier.toJson(object, output: output);
}

//
// json parser
//
typedef _Reviver(var key, var value);

class EntityJsonParser {
  //EntityBuildJsonListener listener; // TODO.. this would be effcient way..
  ISpecialTypeMapHandler mapHandler;
  _Reviver _reviver;
  
  EntityJsonParser(this.mapHandler, {_Reviver reviver}) {
    _reviver = reviver;
  }
  
  EntityBuildJsonListener getListener(Type modelType) =>(_reviver == null)?new EntityBuildJsonListener(mapHandler, modelType)
      :new EntityReviverJsonListener(mapHandler, modelType, _reviver);

  dynamic parse(Type modelType, String json) { 
    EntityBuildJsonListener listener =  getListener(modelType);
    new JsonParser(json, listener).parse();
    return listener.result;
  }
}

class EntityBuildJsonListener extends BuildJsonListener {
  final ISpecialTypeMapHandler mapHandler;
  IClassMirror currentCmirror = null;
  List<IClassMirror> cmirrorStack = [];
  
  EntityBuildJsonListener(this.mapHandler, Type modelType) {
    currentCmirror = ClassMirrorFactory.reflectClass(modelType);
  }
  
  /** Pushes the currently active container (and key, if a [Map]). */
  void pushContainer() {
    super.pushContainer();
    cmirrorStack.add(currentCmirror);
  }

  /** Pops the top container from the [stack], including a key if applicable. */
  void popContainer() {
    super.popContainer();
    currentCmirror = cmirrorStack.removeLast();
  }
  
  void beginObject() {
    super.beginObject();
    if (key != null) {
      IFieldType ft = currentCmirror.fieldTypes[new Symbol(key)];
      if (ft != null) {
        currentCmirror = ClassMirrorFactory.reflectClass(ft.type);
      } else {
        print('>> beginObject ${key}');
        currentCmirror = null;
      }
    }
  }

  void endObject() {
    Map map = currentContainer;
    ConstructorFun spCtor = mapHandler.entityCtor(currentCmirror.type);
    if (spCtor != null) {
      currentContainer = spCtor(map);
    } else {
      // Dart Beans
      IInstanceMirror imiror = currentCmirror.newInstance();
      currentCmirror.fieldTypes.forEach((_, IFieldType ft){
        ConstructorFun vCtor = mapHandler.convert(ft.type);
        var value = map[ft.name];
        imiror.getField(ft.symbol).value = (vCtor != null)?vCtor(value):value;
      });
      currentContainer = imiror.reflectee;
    }
    super.endObject();
  }
}

class EntityReviverJsonListener extends EntityBuildJsonListener {
  final _Reviver reviver;
  EntityReviverJsonListener(ISpecialTypeMapHandler mapHandler, Type modelType, reviver(key, value))
    : super(mapHandler, modelType), this.reviver = reviver;

  void arrayElement() {
    List list = currentContainer;
    value = reviver(list.length, value);
    super.arrayElement();
  }

  void propertyValue() {
    value = reviver(key, value);
    super.propertyValue();
  }

  get result {
    return reviver("", value);
  }
}

//
// entity(including list, map) stringifier
//
class EntityJsonStringifier extends _JsonStringifier {
  final ISpecialTypeMapHandler mapHandler;
  
  EntityJsonStringifier(this.mapHandler): super(null);
  
  String toJson(final obj, {StringSink output}) {
     this..sink = (output != null)?output:new StringBuffer()
    ..seen = [];
    stringifyValue(obj);
    return sink.toString();
  }

  // @Override
  void stringifyValue(final object) {
    if (!stringifyJsonValue(object)) {
      checkCycle(object);
      try {
        // if toJson is defined, it will be used.
        var customJson = object.toJson();
        if (!stringifyJsonValue(customJson)) {
          throw new JsonUnsupportedObjectError(object);
        }
      } catch (e) {
        // if toJson is not defined..
        if (!stringifyJsonValue(object)) {
          stringifyEntity(object);
        }
      }
      seen.removeLast();
    }
  }
  
  void stringifyEntity(final object) {
    // this require dirt:mirrors
    Type t = ClassMirrorFactory.getType(object);
    StringifierFun stringfier = mapHandler.stringifier(t);
    if (stringfier != null) {
      sink.write(stringfier(object));
      return;
    }
    
    //
    IClassMirror cmirror = ClassMirrorFactory.reflectClass(t);
    IInstanceMirror iimirr = cmirror.reflect(object);
    
    sink.write('{');
    int idx = 0;
    Map fmap = cmirror.fieldTypes;
    int lastIdx = fmap.length-1;
    fmap.forEach((k, IFieldType ft){
      sink.write('"${ft.name}": ');
      stringifyValue(iimirr.getField(k).value);
      sink.write((idx == lastIdx)?"":",");
      idx++;
    });
    sink.write('}');   
  }
}
