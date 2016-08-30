/*
 * Copyright (c) 2016 Red Hat, Inc. and others. All rights reserved.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License v1.0 which accompanies this distribution,
 * and is available at http://www.eclipse.org/legal/epl-v10.html
 */
package ch.vorburger.xtendbeans.tests

import org.eclipse.xtend.lib.annotations.Accessors
import org.eclipse.xtend.lib.annotations.FinalFieldsConstructor

@Accessors(PUBLIC_GETTER) // NOT SETTER because that generates void setName(..) instead of BeanWithBuilderBuilder setName(..)
class BeanWithBuilderBuilder implements Builder<BeanWithBuilder> {

    // This class is in a separate file instead of within XtendBeanGeneratorTest
    // so that the private fields are not visible to the test, thus simulating
    // real world beans, which are separate not inner classes, with Builder
    // classes "next" to them.

    String name

    def BeanWithBuilderBuilder setName(String name) {
        this.name = name
        return this
    }

    override BeanWithBuilder build() {
        new BeanWithBuilderImpl(name)
    }

    @FinalFieldsConstructor
    @Accessors(PUBLIC_GETTER)
    static private class BeanWithBuilderImpl implements BeanWithBuilder {
        final String name
    }

}
