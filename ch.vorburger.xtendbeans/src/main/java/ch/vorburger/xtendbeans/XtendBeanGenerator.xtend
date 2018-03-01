/*
 * Copyright (c) 2016 Red Hat, Inc. and others. All rights reserved.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License v1.0 which accompanies this distribution,
 * and is available at http://www.eclipse.org/legal/epl-v10.html
 */
package ch.vorburger.xtendbeans

import com.google.common.base.Preconditions
import com.google.common.collect.Multimap
import com.google.common.collect.Multimaps
import java.lang.reflect.Constructor
import java.lang.reflect.Method
import java.lang.reflect.Modifier
import java.lang.reflect.Parameter
import java.math.BigInteger
import java.util.Arrays
import java.util.Collections
import java.util.List
import java.util.Map
import java.util.Map.Entry
import java.util.Optional
import java.util.Set
import java.util.function.Supplier
import org.eclipse.xtend.lib.annotations.Accessors
import org.eclipse.xtend.lib.annotations.ToString
import org.eclipse.xtext.xbase.lib.Functions.Function0
import org.objenesis.Objenesis
import org.objenesis.ObjenesisStd
import org.objenesis.instantiator.ObjectInstantiator

/**
 * Xtend new (Java Bean) object code generates.
 *
 * Generates highly readable Java Bean object initialization code
 * based on the <a href="https://eclipse.org/xtend/documentation/203_xtend_expressions.html#with-operator">
 * Xtend With Operator</a>.  This syntax is very well suited e.g. to capture expected objects in test code.
 *
 * <p>Xtend is a cool JVM language which itself
 * transpiles to Java source code.  There are <a href="https://eclipse.org/xtend/download.html">plugins
 * for Eclipse and IntelliJ IDEA to work with Xtend</a> available.  It is also possible
 * to use Gradle's Continuous Build mode on the Command Line to get Xtend translated to Java on the fly.
 * (It would even be imaginable to use Xtend's runtime interpreter to allow reading *.xtend files and create
 * objects from them, similar to a JSON or XML unmarshalling library, without any code generation.)
 *
 * <p>PS: This implementation is currently written with performance characteristics intended for
 * manually dumping objects when writing tests.  In particular, no Java Reflection results are
 * cached so far. It is thus not suitable for serializing objects in production.
 *
 * @author Michael Vorburger
 */
class XtendBeanGenerator {

    val Objenesis objenesis = new ObjenesisStd
    val ReflectUtils reflectUtils = new ReflectUtils

    def void print(Object bean) {
        System.out.println('''// Code auto. generated by Michael Vorburger's «class.name»''')
        System.out.println(getExpression(bean))
    }

    def String getExpression(Object bean) {
        stringify(bean).toString
    }

    def protected CharSequence getNewBeanExpression(Object bean) {
        val builderClass = getBuilderClass(bean)
        getNewBeanExpression(bean, builderClass)
    }

    def protected CharSequence getNewBeanExpression(Object bean, Class<?> builderClass) {
        val isUsingBuilder = isUsingBuilder(bean, builderClass)
        val propertiesByName = getBeanProperties(bean, builderClass)
        val propertiesByType = Multimaps.index(propertiesByName.values, [ Property p | p.type ])
        val constructorArguments = constructorArguments(bean, builderClass, propertiesByName, propertiesByType) // This removes some properties
        val filteredRemainingProperties = filter(propertiesByName.filter[name, property |
            ((property.isWriteable || property.isList) && !property.hasDefaultValue)].values)
        CharSequenceExtensions.chomp('''
        «IF isUsingBuilder»(«ENDIF»new «builderClass.shortClassName»«constructorArguments»«IF !filteredRemainingProperties.empty» «getOperator(bean, builderClass)» [«ENDIF»
            «getPropertiesListExpression(filteredRemainingProperties)»
            «getPropertiesListExpression(getAdditionalSpecialProperties(bean, builderClass))»
            «getAdditionalInitializationExpression(bean, builderClass)»
        «IF !filteredRemainingProperties.empty»]«ENDIF»«IF isUsingBuilder»).build()«ENDIF»''')
    }

    def protected String shortClassName(Class<?> clazz) {
        var name = clazz.simpleName
        if (name.isNullOrEmpty)
            name = longClassName(clazz)
        if (name.isNullOrEmpty)
            // just in case subclass overrides longClassName
            name = clazz.name
        name
    }

    def protected String longClassName(Class<?> clazz) {
        clazz.name
    }

    def protected Iterable<Property> filter(Iterable<Property> properties) {
        properties
    }

    def protected Iterable<Property> getAdditionalSpecialProperties(Object bean, Class<?> builderClass) {
        Collections.emptyList
    }

    def protected getPropertiesListExpression(Iterable<Property> properties) '''
        «FOR property : properties»
        «property.name» «IF property.isList && !property.isWriteable»+=«ELSE»=«ENDIF» «stringify(property.valueFunction.get)»
        «ENDFOR»
    '''

    def protected CharSequence getAdditionalInitializationExpression(Object bean, Class<?> builderClass) {
        ""
    }

    def protected isUsingBuilder(Object bean, Class<?> builderClass) {
        !builderClass.equals(bean.class)
    }

    def protected getOperator(Object bean, Class<?> builderClass) {
        "=>"
    }

    def protected isList(Property property) {
        property.type.isAssignableFrom(List) // NOT || property.type.isArray
    }

    def protected Class<?> getBuilderClass(Object bean) {
        val beanClass = bean.class
        val Optional<Class<?>> optBuilderClass = if (beanClass.enclosingClass?.shortClassName?.endsWith("Builder"))
            Optional.of(beanClass.enclosingClass)
        else
            getOptionalBuilderClassByAppendingBuilderToClassName(beanClass)
        optBuilderClass.filter([builderClass | isBuilder(builderClass)]).orElse(beanClass)
    }

    def protected boolean isBuilder(Class<?> builderClass) {
        // make sure that there are public constructors
        builderClass.getConstructors().length > 0
        // and even if there are, make sure that there are not only static methods
            && atLeastOneNonStatic(builderClass.methods)
    }

    def private boolean atLeastOneNonStatic(Method[] methods) {
        for (method : methods) {
            if (!Modifier.isStatic(method.modifiers)
                && !method.declaringClass.equals(Object)
            ) {
                return true
            }
        }
        return false;
    }

    def protected Optional<Class<?>> getOptionalBuilderClassByAppendingBuilderToClassName(Class<?> klass) {
        val classLoader = klass.classLoader
        val buildClassName = klass.name + "Builder"
        try {
            Optional.of(Class.forName(buildClassName, false, classLoader))
        } catch (ClassNotFoundException e) {
            // This can easily happen frequently, and is expected; so do not LOG
            Optional.empty
        }
    }

    def protected constructorArguments(Object bean, Class<?> builderClass, Map<String, Property> propertiesByName, Multimap<Class<?>, Property> propertiesByType) {
        val constructors = builderClass.constructors
        if (constructors.isEmpty) ''''''
        else {
            val constructor = findSuitableConstructor(builderClass, constructors, propertiesByName, propertiesByType)
            if (constructor === null) ''''''
            else {
                val parameters = constructor.parameters
                '''«FOR parameter : parameters BEFORE '(' SEPARATOR ', ' AFTER ')'»«getConstructorParameterValue(parameter, propertiesByName, propertiesByType)»«ENDFOR»'''
            }
        }
    }

    def protected Constructor<?> findSuitableConstructor(Class<?> builderClass, Constructor<?>[] constructors, Map<String, Property> propertiesByName, Multimap<Class<?>, Property> propertiesByType) {
        try {
            val possibleConstructors = findAllPossibleConstructors(constructors, propertiesByName, propertiesByType, true)
            return findSuitableConstructorINTERNAL(builderClass, possibleConstructors, propertiesByName, propertiesByType)
        } catch (IllegalStateException e) {
            // This can easily happen frequently, and is expected; so do not LOG
            val possibleConstructorsWithDefaultValues = findAllPossibleConstructors(constructors, propertiesByName, propertiesByType, false)
            return findSuitableConstructorINTERNAL(builderClass, possibleConstructorsWithDefaultValues, propertiesByName, propertiesByType)
        }
    }

    def private Constructor<?> findSuitableConstructorINTERNAL(Class<?> builderClass, List<Constructor<?>> possibleConstructors, Map<String, Property> propertiesByName, Multimap<Class<?>, Property> propertiesByType) {
        val propertyNames = propertiesByName.keySet
        if (possibleConstructors.isEmpty)
            throw new IllegalStateException("No suitable constructor found on " + builderClass.name
                + ", write a *Builder to help, as none of these match: "
                + possibleConstructors + "; for: " + propertyNames)
        // Now filter it out to retain only those with the highest number of parameters
        val randomMaxParametersConstructor = possibleConstructors.maxBy[parameterCount]
        val retainedConstructors = possibleConstructors.filter[it.parameterCount == randomMaxParametersConstructor.parameterCount]
        if (retainedConstructors.size == 1)
            retainedConstructors.head
        else if (retainedConstructors.empty)
            throw new IllegalStateException("No suitable constructor found, write a *Builder to help, as none of these match: "
                + possibleConstructors + "; for: " + propertyNames)
        else {
            resolveAmbiguousConstructorChoice(retainedConstructors, propertiesByName, propertiesByType)
                .orElseThrow([|
                    new IllegalStateException("More than 1 suitable constructor found; remove one or write a *Builder to help instead: "
                    + retainedConstructors + "; for: " + propertyNames)
            ])
        }
    }

    def protected List<Constructor<?>> findAllPossibleConstructors(Constructor<?>[] constructors,
            Map<String, Property> propertiesByName, Multimap<Class<?>, Property> propertiesByType,
            boolean considerDefault) {

        val possibleParameterByNameAndTypeMatchingConstructors = newArrayList
        val possibleParameterOnlyByTypeMatchingConstructors = newArrayList
        for (Constructor<?> constructor : constructors) {
            if (isSuitableConstructorByName(constructor, propertiesByName, considerDefault)) {
                possibleParameterByNameAndTypeMatchingConstructors.add(constructor)
            } else if (isSuitableConstructorByType(constructor, propertiesByType, considerDefault)) {
                // Fallback.. attempt to match just based on type, not name
                possibleParameterOnlyByTypeMatchingConstructors.add(constructor)
            }
        }
        return
            if (!possibleParameterByNameAndTypeMatchingConstructors.isEmpty)
                possibleParameterByNameAndTypeMatchingConstructors
            else
                possibleParameterOnlyByTypeMatchingConstructors
    }

    def protected Optional<Constructor<?>> resolveAmbiguousConstructorChoice(Constructor<?>[] constructors, Map<String, Property> propertiesByName, Multimap<Class<?>, Property> propertiesByType) {
        chooseUnionConstructor(constructors, propertiesByName, propertiesByType)
            // use or([| ..]) to add other ambiguous constructor choice resolution strategies:
            // .or([| chooseUnionConstructor(constructors, propertiesByName, propertiesByType)])
    }
/*
    def private <T> Optional<T> or(Optional<T> optional, Supplier<Optional<T>> supplier) {
        // this is a back-port of a new method of Optonal from JDK 9, slightly simplified (without <? extend T>
        if (optional.isPresent) {
            optional
        } else {
            supplier.get
        }
    }  */

    /**
     * If there are exactly 2 constructors with each 1 argument, and one of them takes a String and the other doesn't, then pick the other.
     */
    def protected Optional<Constructor<?>> chooseUnionConstructor(Constructor<?>[] constructors, Map<String, Property> propertiesByName, Multimap<Class<?>, Property> propertiesByType) {
        if (constructors.length == 2) {
            val constructor1Params = constructors.get(0).parameters
            val constructor2Params = constructors.get(1).parameters
            if (constructor1Params.length == 1 && constructor2Params.length == 1) {
                if (!constructor1Params.get(0).type.isLikeString && constructor2Params.get(0).type.isLikeString) {
                    return Optional.of(constructors.get(0))
                }
                if (constructor1Params.get(0).type.isLikeString && !constructor2Params.get(0).type.isLikeString) {
                    return Optional.of(constructors.get(1))
                }
            }
        }
        Optional.empty
    }

    def protected boolean isLikeString(Class<?> type) {
        val charArrayClass = Class.forName("[C") // Xtend does not allow char[].class
        type.equals(String) || type.equals(charArrayClass)
    }

    def protected isSuitableConstructorByName(Constructor<?> constructor, Map<String, Property> propertiesByName, boolean considerDefault) {
        var suitableConstructor = true
        for (parameter : constructor.parameters) {
            val parameterName = getParameterName(parameter)
            if (!propertiesByName.containsKey(parameterName)) {
                suitableConstructor = false
            } else {
                val property = propertiesByName.get(parameterName)
                suitableConstructor = isParameterSuitableForProperty(parameter, property, considerDefault)
            }
        }
        suitableConstructor
    }

    def protected isSuitableConstructorByType(Constructor<?> constructor, Multimap<Class<?>, Property> propertiesByType, boolean considerDefault) {
        var suitableConstructor = true
        for (parameter : constructor.parameters) {
            val matchingProperties = propertiesByType.get(parameter.type)
            if (matchingProperties.size != 1) {
                suitableConstructor = false
            } else {
                val property = matchingProperties.head
                suitableConstructor = isParameterSuitableForProperty(parameter, property, considerDefault)
            }
        }
        suitableConstructor
    }

    def protected isParameterSuitableForProperty(Parameter parameter, Property property, boolean considerDefault) {
        if (!parameter.type.equals(property.type)) {
            return false
        } else if (considerDefault && property.hasDefaultValue) {
            return false
        } else {
            return true
        }
    }

    def protected getConstructorParameterValue(Parameter parameter, Map<String, Property> propertiesByName, Multimap<Class<?>, Property> propertiesByType) {
        val constructorParameterName = getParameterName(parameter)
        val propertyByName = propertiesByName.get(constructorParameterName)
        if (propertyByName !== null) {
            propertiesByName.remove(propertyByName.name)
            return stringify(propertyByName.valueFunction.get)
        } else {
            // Fallback.. attempt to match just based on type, not name
            // NOTE In this case we already made sure earlier in isSuitableConstructorByType that there is exactly one matching by type
            val matchingProperties = propertiesByType.get(parameter.type)
            if (matchingProperties.size == 1) {
                val propertyByType = matchingProperties.head
                propertiesByName.remove(propertyByType.name)
                return stringify(propertyByType.valueFunction.get)
            } else if (matchingProperties.size > 1) {
                throw new IllegalStateException(
                    "Constructor parameter '" + constructorParameterName + "' of "
                    + parameter.declaringExecutable + " matches no property by name, "
                    + "but more than 1 property by type: "  + matchingProperties
                    + ", consider writing a *Builder; all bean's properties: "
                    + propertiesByName.keySet)
            } else { // matchingProperties.isEmpty
                throw new IllegalStateException(
                    "Constructor parameter '" + constructorParameterName + "' of "
                    + parameter.declaringExecutable + " not matching by name or type, "
                    + "consider writing a *Builder; bean's properties: "
                    + propertiesByName.keySet)
            }
        }
    }

    def protected getParameterName(Parameter parameter) {
        if (!parameter.isNamePresent)
            // https://docs.oracle.com/javase/tutorial/reflect/member/methodparameterreflection.html
            throw new IllegalStateException(
                "Needs javac -parameters; or, in Eclipse: 'Store information about method parameters (usable via "
                + "reflection)' in Window -> Preferences -> Java -> Compiler, for: " + parameter.declaringExecutable);
        parameter.name
    }

    def protected CharSequence stringify(Object object) {
        switch object {
            case null : "null"
            case object.class.isArray : stringifyArray(object)
            Set<?>    : '''
                        #{
                            «FOR element : object SEPARATOR ','»
                                «stringify(element)»
                            «ENDFOR»
                        }'''
            Iterable<?> : '''
                        #[
                            «FOR element : object SEPARATOR ','»
                            «stringify(element)»
                            «ENDFOR»
                        ]'''
            Map<?,?>  : stringify(object.entrySet)
            Entry<?,?>: '''«stringify(object.key)» -> «stringify(object.value)»'''
            String    : '''"«object»"'''
            Integer   : '''«object»'''
            Long      : '''«object»L'''
            Boolean   : '''«object»'''
            Byte      : '''«object»'''
            Character : '''«"'"»«object»«"'"»'''
            Double    : '''«object»d'''
            Float     : '''«object»f'''
            Short     : '''«object» as short'''
            BigInteger: '''«object»bi'''
            Enum<?>   : '''«object.declaringClass.shortClassName».«object.name»'''
            Class<?>  : stringify(object)
            default   : '''«getNewBeanExpression(object)»'''
        }
    }

    def protected stringify(Class<?> aClass) {
        // @Override this method if you prefer using aClass.shortClassName than longClassName
        aClass.longClassName
    }

    def protected CharSequence stringifyArray(Object array) {
        switch array {
            byte[]    : '''
                        #[
                            «FOR e : array SEPARATOR ','»
                            «stringify(e)»
                            «ENDFOR»
                        ]'''
            boolean[] : '''
                        #[
                            «FOR e : array SEPARATOR ','»
                            «stringify(e)»
                            «ENDFOR»
                        ]'''
            char[] : '''
                        #[
                            «FOR e : array SEPARATOR ','»
                            «stringify(e)»
                            «ENDFOR»
                        ]'''
            double[] : '''
                        #[
                            «FOR e : array SEPARATOR ','»
                            «stringify(e)»
                            «ENDFOR»
                        ]'''
            float[] : '''
                        #[
                            «FOR e : array SEPARATOR ','»
                            «stringify(e)»
                            «ENDFOR»
                        ]'''
            int[]     : '''
                        #[
                            «FOR e : array SEPARATOR ','»
                            «stringify(e)»
                            «ENDFOR»
                        ]'''
            long[]    : '''
                        #[
                            «FOR e : array SEPARATOR ','»
                            «stringify(e)»
                            «ENDFOR»
                        ]'''
            short[]    : '''
                        #[
                            «FOR e : array SEPARATOR ','»
                            «stringify(e)»
                            «ENDFOR»
                        ]'''
            Object[]  : '''
                        #[
                            «FOR e : array SEPARATOR ','»
                            «stringify(e)»
                            «ENDFOR»
                        ]'''
        }
    }

    def protected Map<String, Property> getBeanProperties(Object bean, Class<?> builderClass) {
        val defaultValuesBean = newEmptyBeanForDefaultValues(builderClass)
        val properties = reflectUtils.getProperties(builderClass)
        val propertiesMap = newLinkedHashMap()
        for (property : properties) {
            if (isPropertyConsidered(builderClass, property.name, property.type))
                propertiesMap.put(property.name, new Property(
                    property.name,
                    property.isWriteable,
                    property.type,
                    [ | property.invokeGetter(bean) ],
                    property.invokeGetter(defaultValuesBean)
                ))
        }
        return propertiesMap
    }

    def protected boolean isPropertyConsidered(Class<?> builderClass, String propertyName, Class<?> type) {
        true
    }

    def protected newEmptyBeanForDefaultValues(Class<?> builderClass) {
        try {
            builderClass.newInstance
        } catch (InstantiationException e) {
            // Use http://objenesis.org if normal Java reflection cannot create new instance
            val ObjectInstantiator<?> builderClassInstantiator = objenesis.getInstantiatorOf(builderClass)
            builderClassInstantiator.newInstance
        }
    }

    @ToString
    @Accessors(PUBLIC_GETTER)
    protected static class Property {
        final String name
        final boolean isWriteable
        final Class<?> type
        final Supplier<Object> valueFunction
        final Object defaultValue

        // @Accessors and @FinalFieldsConstructor don't do null checks
        new(String name, boolean isWriteable, Class<?> type, Function0<Object> valueFunction, Object defaultValue) {
            this.name = Preconditions.checkNotNull(name, "name")
            this.isWriteable = isWriteable
            this.type = Preconditions.checkNotNull(type, "type")
            this.valueFunction = Preconditions.checkNotNull(valueFunction, "valueFunction")
            this.defaultValue = defaultValue
        }

        def boolean hasDefaultValue() {
            val value = valueFunction.get
            return if (value === null && defaultValue === null) {
                true
            } else if (value !== null && defaultValue !== null) {
                if (!type.isArray)
                    value == defaultValue
                else switch defaultValue {
                    byte[]    : Arrays.equals(value as byte[],    defaultValue)
                    boolean[] : Arrays.equals(value as boolean[], defaultValue)
                    char[]    : Arrays.equals(value as char[],    defaultValue)
                    double[]  : Arrays.equals(value as double[],  defaultValue)
                    float[]   : Arrays.equals(value as float[],   defaultValue)
                    int[]     : Arrays.equals(value as int[],     defaultValue)
                    long[]    : Arrays.equals(value as long[],    defaultValue)
                    short[]   : Arrays.equals(value as short[],   defaultValue)
                    Object[]  : Arrays.deepEquals(value as Object[], defaultValue)
                    default   : value.equals(defaultValue)
                }
            } else if (value === null || defaultValue === null) {
                false
            }
        }
    }
}
