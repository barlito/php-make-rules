# Include development rules
include make/stack/development.mk

# Include rules to check code style
include make/app/code_style.mk

# Include composer rules
include make/app/composer.mk

# Include symfony rules
include make/app/symfony.mk

# Include doctrine rules
include make/app/doctrine.mk

